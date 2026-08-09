import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytdlp_service.dart';

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
  final Map<String, Future<String>> _inflight = {};

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
        .where((e) => e is File && p.basenameWithoutExtension(e.path) == videoId)
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    // Puede haber variantes (m4a/opus/webm): quedarse con la más reciente.
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final best = files.first;
    try {
      // Touch: actualizar el mtime para que el LRU la considere reciente.
      await best.setLastModified(DateTime.now());
    } catch (_) {
      // Si el FS no lo permite, no es crítico.
    }
    return best.path;
  }

  /// Devuelve la ruta local de la pista, descargándola si hace falta.
  ///
  /// Las llamadas concurrentes para el mismo [videoId] comparten una única
  /// descarga (no se descarga dos veces).
  Future<String> ensure(String videoId, {String? title}) async {
    final cached = await cachedPath(videoId);
    if (cached != null) return cached;

    final inFlight = _inflight[videoId];
    if (inFlight != null) return inFlight;

    final future = _download(videoId, title: title);
    _inflight[videoId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(videoId);
    }
  }

  Future<String> _download(String videoId, {String? title}) async {
    final dir = await cacheDir();
    downloadingId.value = videoId;
    progress.value = null;
    try {
      final path = await ytdlp.downloadAudio(
        videoId,
        outputDir: dir.path,
        title: title,
        onProgress: (pct) => progress.value = pct,
      );
      await _enforceLimit(dir);
      return path;
    } finally {
      if (downloadingId.value == videoId) downloadingId.value = null;
      progress.value = null;
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
    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
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
}
