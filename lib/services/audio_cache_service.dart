import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytdlp_service.dart';

/// Fuente local de reproducción: una ruta ya cacheada (instantánea) o un
/// archivo parcial que aún se está descargando (reproducción progresiva).
class StreamingSource {
  final String path;

  /// `true` si ya estaba cacheado y se reproduce al instante.
  final bool fromCache;

  const StreamingSource(this.path, {this.fromCache = false});
}

/// Resumen del contenido actual del caché (para la pantalla de
/// configuración: tamaño usado y nº de archivos).
class CacheStats {
  const CacheStats({required this.fileCount, required this.bytes});

  /// Número de archivos cacheados.
  final int fileCount;

  /// Tamaño total en bytes.
  final int bytes;

  bool get isEmpty => fileCount == 0 && bytes == 0;
}

/// Caché local de audio descargado con yt-dlp.
///
/// Primera reproducción: descarga la pista completa al disco y la reproduce
/// desde el archivo local (estable, sin cortes de stream de YouTube).
/// Sesiones posteriores: reproduce al instante desde el caché.
///
/// El caché está acotado por tamaño: cuando supera [maxSizeBytes] se eliminan
/// los archivos menos recientemente usados (LRU por mtime).
class AudioCacheService {
  AudioCacheService({
    required this.ytdlp,
    int? maxSizeBytes,
    this.directoryOverride,
  }) : maxSizeBytes = maxSizeBytes ?? _maxFromEnv();

  /// Tamaño máximo por defecto del caché: 2 GiB.
  static const int defaultMaxSize = 2 * 1024 * 1024 * 1024;

  /// Límite del caché desde la variable de entorno `SCRUP_CACHE_MAX_MB`
  /// (en MiB), o el [defaultMaxSize] si no está definida o es inválida.
  static int _maxFromEnv() {
    final raw = Platform.environment['SCRUP_CACHE_MAX_MB'];
    if (raw != null) {
      final mb = int.tryParse(raw);
      if (mb != null && mb > 0) return mb * 1024 * 1024;
    }
    return defaultMaxSize;
  }

  final YtDlpService ytdlp;
  final int maxSizeBytes;

  /// Directorio a usar directamente (tests). Si es null, se resuelve el
  /// directorio de soporte de la aplicación (persistente entre sesiones).
  final Directory? directoryOverride;

  /// Id de la pista que se está descargando ahora mismo, o null.
  final ValueNotifier<String?> downloadingId = ValueNotifier<String?>(null);

  /// Progreso de la descarga actual (0.0–1.0), o null si no hay ninguna.
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  /// Descargas en curso por videoId (dedupe de peticiones concurrentes).
  /// El slot se reserva con un [Completer] de forma SÍNCRONA (antes de
  /// cualquier await) para que dos llamadas simultáneas al mismo videoId
  /// compartan la misma descarga en vez de arrancar dos procesos.
  final Map<String, Completer<StreamingDownload>> _inflight = {};

  Directory? _dir;

  /// Directorio raíz del caché (creándolo si no existe).
  Future<Directory> cacheDir() async {
    final override = directoryOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'audio_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Ruta local de la pista si ya está cacheada (actualizando el LRU), o
  /// `null` si hay que descargarla.
  Future<String?> cachedPath(String videoId) async {
    final dir = await cacheDir();
    final files = await dir
        .list()
        .where(
          (e) => e is File && p.basenameWithoutExtension(e.path) == videoId,
        )
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    // Puede haber variantes (m4a/opus/webm): quedarse con la más reciente.
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final best = files.first;
    try {
      // Touch: actualizar el mtime para que el LRU la considere reciente.
      await best.setLastModified(DateTime.now());
    } catch (_) {
      // Si el FS no lo permite, no es crítico.
    }
    return best.path;
  }

  /// Fuente para reproducir con reproducción progresiva: devuelve al
  /// instante si la pista ya está cacheada; si no, arranca la descarga y
  /// resuelve en cuanto hay datos reproducibles (el archivo `.part`), que
  /// se reproduce mientras la descarga continúa en segundo plano y termina
  /// quedando cacheada en disco.
  Future<StreamingSource> ensureStreaming(
    String videoId, {
    String? title,
  }) async {
    final cached = await cachedPath(videoId);
    if (cached != null) return StreamingSource(cached, fromCache: true);

    // Dedupe de llamadas concurrentes: reservar el slot de forma síncrona
    // (sin awaits intermedios) para que la segunda llamada reutilice la
    // descarga de la primera en vez de arrancar otro proceso.
    var completer = _inflight[videoId];
    if (completer == null) {
      completer = Completer<StreamingDownload>();
      _inflight[videoId] = completer;
      unawaited(_startDownload(videoId, completer, title: title));
    }
    final download = await completer.future;
    final path = await download.playablePath.timeout(
      const Duration(seconds: 25),
    );
    return StreamingSource(path);
  }

  /// Arranca la descarga en streaming en segundo plano y completa
  /// [completer] cuando yt-dlp devuelve el [StreamingDownload]. Si el
  /// arranque falla, completa con error y libera el slot (para permitir
  /// reintentos).
  Future<void> _startDownload(
    String videoId,
    Completer<StreamingDownload> completer, {
    String? title,
  }) async {
    try {
      final dir = await cacheDir();
      downloadingId.value = videoId;
      progress.value = null;
      final download = await ytdlp.startStreaming(
        videoId,
        outputDir: dir.path,
        title: title,
        onProgress: (pct) => progress.value = pct,
      );
      // La limpieza (LRU al terminar, borrado del `.part` si falla y
      // liberación del slot) la hace [_trackDownload] cuando la descarga
      // termina de verdad.
      _trackDownload(download, videoId, completer);
      if (!completer.isCompleted) completer.complete(download);
    } catch (e) {
      if (downloadingId.value == videoId) {
        downloadingId.value = null;
        progress.value = null;
      }
      if (identical(_inflight[videoId], completer)) {
        _inflight.remove(videoId);
      }
      if (!completer.isCompleted) completer.completeError(e);
    }
  }

  /// Sigue una descarga en segundo plano: cuando termina aplica el límite
  /// LRU y libera el slot; si falla, borra el `.part` incompleto. Nunca
  /// lanza (es un fire-and-forget de limpieza).
  void _trackDownload(
    StreamingDownload download,
    String videoId,
    Completer<StreamingDownload> completer,
  ) {
    unawaited(() async {
      final Directory dir;
      try {
        dir = await cacheDir();
      } catch (_) {
        return;
      }
      try {
        await download.finalPath;
        await _enforceLimit(dir);
      } catch (_) {
        try {
          await _cleanupPartial(dir, videoId);
        } catch (_) {
          // Silencioso: el cleanup no debe romper nada.
        }
      } finally {
        if (identical(_inflight[videoId], completer)) {
          _inflight.remove(videoId);
        }
        if (downloadingId.value == videoId) {
          downloadingId.value = null;
          progress.value = null;
        }
      }
    }());
  }

  /// Borra los `.part` incompletos de [videoId] (descargas fallidas).
  Future<void> _cleanupPartial(Directory dir, String videoId) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) {
        final name = p.basename(e.path);
        if (name.startsWith('$videoId.') && name.endsWith('.part')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  }

  /// Elimina archivos desde el más antiguo (LRU) hasta quedar bajo el límite.
  Future<void> _enforceLimit(Directory dir) async {
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    var total = 0;
    for (final f in files) {
      total += f.statSync().size;
    }
    if (total <= maxSizeBytes) return;
    files.sort(
      (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
    );
    for (final f in files) {
      if (total <= maxSizeBytes) return;
      final size = f.statSync().size;
      await f.delete();
      total -= size;
    }
  }

  /// Borra todo el caché.
  Future<void> clear() async {
    final dir = await cacheDir();
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }

  /// Resumen del caché: número de archivos y tamaño total en bytes.
  Future<CacheStats> stats() async {
    final dir = await cacheDir();
    var count = 0;
    var bytes = 0;
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File) {
          count++;
          try {
            bytes += e.statSync().size;
          } catch (_) {
            // Archivo desaparecido durante el conteo: se ignora.
          }
        }
      }
    }
    return CacheStats(fileCount: count, bytes: bytes);
  }
}
