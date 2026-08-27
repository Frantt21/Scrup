import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

  /// Tamaño máximo por defecto del caché: 40 GiB.
  static const int defaultMaxSize = 40 * 1024 * 1024 * 1024;

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
  int maxSizeBytes;

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

  /// Máximo de descargas de PRECARGA simultáneas. La de la pista en
  /// reproducción no cuenta: va por su propio carril, y además las precargas
  /// le ceden el ancho de banda esperando a que termine.
  static const int maxConcurrentPreloads = 2;

  /// Precargas en curso (recursos limitados: nunca más de
  /// [maxConcurrentPreloads] procesos yt-dlp de fondo a la vez).
  int _activePreloads = 0;

  /// Esperas por un slot de precarga (FIFO).
  final List<Completer<void>> _preloadWaiters = [];

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
  ///
  /// El escaneo del directorio corre en un isolate de fondo: listar +
  /// statSync por archivo en el hilo UI congelaría la interfaz con un caché
  /// grande (se llama en cada reproducción). Solo se cruzan valores
  /// enviables (paths) entre isolates.
  Future<String?> cachedPath(String videoId) async {
    final dir = await cacheDir();
    final dirPath = dir.path;
    return Isolate.run(() {
      final d = Directory(dirPath);
      if (!d.existsSync()) return null;
      final files = d
          .listSync()
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
        best.setLastModifiedSync(DateTime.now());
      } catch (_) {
        // Si el FS no lo permite, no es crítico.
      }
      return best.path;
    });
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

  /// Precarga una pista al caché en segundo plano (para que el salto de
  /// canción sea instantáneo), con RECURSOS LIMITADOS:
  /// - como mucho [maxConcurrentPreloads] precargas a la vez (semáforo),
  /// - no compite por ancho de banda con la descarga de la pista que se está
  ///   reproduciendo (espera a que termine),
  /// - dedupe con [_inflight]: si la pista ya se está descargando (precarga o
  ///   reproducción), se reutiliza;
  /// - best-effort: si falla (sin red, 403…), se ignora sin propagar.
  Future<void> preload(String videoId, {String? title}) async {
    try {
      if (await cachedPath(videoId) != null) return;
      // Ceder el ancho de banda: mientras se descargue la pista en
      // reproducción (downloadingId activo), esperar antes de precargar.
      while (downloadingId.value != null) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      await _acquirePreloadSlot();
      try {
        // Re-chequear dentro del slot: entre la primera comprobación y aquí
        // otra petición pudo cachear la pista.
        if (await cachedPath(videoId) != null) return;
        // Volver a ceder el ancho de banda justo antes de arrancar: la
        // reproducción pudo empezar tras la primera espera (carrera de
        // arranque — best-effort, pero se minimiza).
        while (downloadingId.value != null) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        var completer = _inflight[videoId];
        if (completer == null) {
          completer = Completer<StreamingDownload>();
          _inflight[videoId] = completer;
          unawaited(
            _startDownload(videoId, completer, title: title, background: true),
          );
        }
        try {
          final download = await completer.future;
          // Mantener el slot hasta que la descarga termine en disco: así el
          // semáforo acota procesos yt-dlp reales, no solo el arranque.
          await download.finalPath;
        } catch (_) {
          // Fallo de descarga: _trackDownload limpia el .part incompleto;
          // aquí solo se libera el slot (finally).
        }
      } finally {
        _releasePreloadSlot();
      }
    } catch (_) {
      // Best-effort: una precarga fallida nunca debe propagarse.
    }
  }

  /// Reserva un slot de precarga (espera si ya hay [maxConcurrentPreloads]
  /// activas).
  Future<void> _acquirePreloadSlot() async {
    if (_activePreloads < maxConcurrentPreloads) {
      _activePreloads++;
      return;
    }
    final waiter = Completer<void>();
    _preloadWaiters.add(waiter);
    await waiter.future;
  }

  /// Libera un slot de precarga: despierta al siguiente esperando (FIFO) o
  /// decrementa el contador.
  void _releasePreloadSlot() {
    if (_preloadWaiters.isNotEmpty) {
      _preloadWaiters.removeAt(0).complete();
    } else {
      _activePreloads--;
    }
  }

  /// Arranca la descarga en streaming en segundo plano y completa
  /// [completer] cuando yt-dlp devuelve el [StreamingDownload]. Si el
  /// arranque falla, completa con error y libera el slot (para permitir
  /// reintentos).
  ///
  /// Con [background] (precarga) NO se tocan los notifiers de progreso de la
  /// UI ([downloadingId]/[progress]): esos reflejan solo la descarga de la
  /// pista que se está preparando/reproduciendo.
  Future<void> _startDownload(
    String videoId,
    Completer<StreamingDownload> completer, {
    String? title,
    bool background = false,
  }) async {
    try {
      final dir = await cacheDir();
      if (!background) {
        downloadingId.value = videoId;
        progress.value = null;
      }
      final download = await ytdlp.startStreaming(
        videoId,
        outputDir: dir.path,
        title: title,
        onProgress: background ? null : (pct) => progress.value = pct,
      );
      // La limpieza (LRU al terminar, borrado del `.part` si falla y
      // liberación del slot) la hace [_trackDownload] cuando la descarga
      // termina de verdad.
      _trackDownload(download, videoId, completer);
      if (!completer.isCompleted) completer.complete(download);
    } catch (e) {
      if (!background && downloadingId.value == videoId) {
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
  ///
  /// Corre en un isolate de fondo: sumar tamaños + statSync + borrados en el
  /// hilo UI congelaría la interfaz con un caché grande (se llama al terminar
  /// cada descarga). Solo se cruzan valores enviables (paths/ints).
  Future<void> _enforceLimit(Directory dir) async {
    final dirPath = dir.path;
    final limit = maxSizeBytes;
    await Isolate.run(() {
      final d = Directory(dirPath);
      if (!d.existsSync()) return;
      final files = d.listSync().whereType<File>().toList();
      var total = 0;
      for (final f in files) {
        total += f.statSync().size;
      }
      if (total <= limit) return;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      for (final f in files) {
        if (total <= limit) return;
        final size = f.statSync().size;
        f.deleteSync();
        total -= size;
      }
    });
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
  ///
  /// Corre en un isolate de fondo (la pantalla de configuración lo invoca al
  /// abrir): listar + statSync de un caché grande en el hilo UI congelaría
  /// la interfaz.
  Future<CacheStats> stats() async {
    final dir = await cacheDir();
    final dirPath = dir.path;
    return Isolate.run(() {
      var count = 0;
      var bytes = 0;
      final d = Directory(dirPath);
      if (d.existsSync()) {
        for (final e in d.listSync()) {
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
    });
  }
}
