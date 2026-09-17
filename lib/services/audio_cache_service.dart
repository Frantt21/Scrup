import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_log.dart';
import 'ytdlp_service.dart';

/// Local audio source: cached file or partial download for progressive playback.
class StreamingSource {
  final String path;
  final bool fromCache;
  const StreamingSource(this.path, {this.fromCache = false});
}

/// Cache size summary for the settings screen.
class CacheStats {
  const CacheStats({required this.fileCount, required this.bytes});
  final int fileCount;
  final int bytes;
  bool get isEmpty => fileCount == 0 && bytes == 0;
}

/// Local audio cache with LRU eviction. First play downloads to disk,
/// subsequent plays serve from cache instantly.
class AudioCacheService {
  AudioCacheService({
    required this.ytdlp,
    int? maxSizeBytes,
    this.directoryOverride,
  }) : maxSizeBytes = maxSizeBytes ?? _maxFromEnv();

  static const int defaultMaxSize = 40 * 1024 * 1024 * 1024;

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
  final Directory? directoryOverride;
  final ValueNotifier<String?> downloadingId = ValueNotifier<String?>(null);
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  // Progress (0..1) of background preloads (playlist downloads), keyed by
  // videoId. Foreground (user-waiting) downloads use [progress] instead.
  final ValueNotifier<Map<String, double>> backgroundProgress =
      ValueNotifier(const {});

  // In-flight downloads keyed by videoId (dedup concurrent requests). The slot is reserved synchronously before any await.
  final Map<String, Completer<StreamingDownload>> _inflight = {};

  static const int maxConcurrentPreloads = 3;

  int _activePreloads = 0;

  final List<Completer<void>> _preloadWaiters = [];

  Directory? _dir;

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

  // Returns cached file path (touching LRU) or null.
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
      // Keep newest variant (m4a/opus/webm).
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final best = files.first;
      try {
        best.setLastModifiedSync(DateTime.now());
      } catch (_) {
      }
      return best.path;
    });
  }

  // Returns cached source immediately, or starts streaming download
  // and resolves once the .part file is playable.
  Future<StreamingSource> ensureStreaming(
    String videoId, {
    String? title,
  }) async {
    final cached = await cachedPath(videoId);
    if (cached != null) {
      debugPrint('[audio] cache HIT id=$videoId -> $cached');
      return StreamingSource(cached, fromCache: true);
    }
    debugPrint('[audio] cache MISS id=$videoId (streaming)');

    var completer = _inflight[videoId];
    if (completer == null) {
      completer = Completer<StreamingDownload>();
      _inflight[videoId] = completer;
      unawaited(_startDownload(videoId, completer, title: title));
    } else {
      debugPrint('[audio] id=$videoId ya en descarga, reutilizando slot');
    }
    final download = await completer.future;
    final path = await download.playablePath.timeout(
      const Duration(seconds: 25),
    );
    debugPrint('[audio] id=$videoId playable -> $path');
    return StreamingSource(path);
  }

  /// How many upcoming tracks are "woken up" from disk (page cache).
  static const int maxWarmUpcoming = 5;

  /// Header bytes read per file: enough for the OS to bring the start of the container (moov/stco in m4a) into the page cache.
  static const int _warmHeaderBytes = 1 << 20;

  // Dedupe tracks already warmed in this session (cheap in-memory set).
  final Set<String> _warmedIds = {};

  /// Path 2 of prefetch: tracks already cached on disk. Unlike [preload] (download), this has no network I/O: each file is opened in an isolate and its first bytes are read so the OS brings them into the page cache before the current track ends. When the track is opened, the backend (ExoPlayer) finds a hot header and the `open()` does not hit cold disk (no transition jank).
  void warmUpcoming(List<String> videoIds) {
    for (final id in videoIds) {
      if (_warmedIds.contains(id)) continue;
      _warmedIds.add(id);
      if (_warmedIds.length > 200) _warmedIds.clear();
      unawaited(_warmOne(id));
    }
  }

  Future<void> _warmOne(String videoId) async {
    try {
      final path = await cachedPath(videoId);
      if (path == null) return; // no cacheado: lo cubre `preload` (descarga)
      final warmPath = path;
      final bytes = await Isolate.run(() => _readHeaderBytes(warmPath));
      if (bytes > 0) {
        appLog('PERF', 'warm header +${bytes}B id=$videoId');
      }
    } catch (_) {}
  }

  /// Read the first [_warmHeaderBytes] of the file (INSIDE the isolate: all disk I/O stays off the UI thread).
  static int _readHeaderBytes(String path) {
    final f = File(path);
    if (!f.existsSync()) return 0;
    final raf = f.openSync();
    try {
      final len = f.lengthSync();
      final take = len > _warmHeaderBytes ? _warmHeaderBytes : len;
      if (take <= 0) return 0;
      final buf = List<int>.filled(take, 0, growable: false);
      return raf.readIntoSync(buf, 0, take);
    } finally {
      raf.closeSync();
    }
  }

  // Background preload with a concurrency limit. Reports per-id progress via
  // [backgroundProgress] so playlist batch downloads can show per-row loaders.
  // Best-effort: never throws, callers verify via [cachedPath].
  Future<void> preload(String videoId, {String? title}) async {
    try {
      if (await cachedPath(videoId) != null) {
        debugPrint('[audio] preload SKIP id=$videoId (ya en caché)');
        return;
      }
      await _acquirePreloadSlot();
      try {
        if (await cachedPath(videoId) != null) return;
        debugPrint('[audio] preload start id=$videoId');
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
          await download.finalPath;
        } catch (_) {}
      } finally {
        _releasePreloadSlot();
      }
    } catch (_) {}
  }

  Future<void> _acquirePreloadSlot() async {
    if (_activePreloads < maxConcurrentPreloads) {
      _activePreloads++;
      return;
    }
    final waiter = Completer<void>();
    _preloadWaiters.add(waiter);
    await waiter.future;
  }

  void _releasePreloadSlot() {
    if (_preloadWaiters.isNotEmpty) {
      _preloadWaiters.removeAt(0).complete();
    } else {
      _activePreloads--;
    }
  }

  Future<void> _startDownload(
    String videoId,
    Completer<StreamingDownload> completer, {
    String? title,
    bool background = false,
  }) async {
    debugPrint('[audio] download start id=$videoId '
        '${background ? '(fondo)' : '(frente)'}');
    try {
      final dir = await cacheDir();
      if (!background) {
        downloadingId.value = videoId;
        progress.value = null;
      } else {
        _setBackgroundProgress(videoId, null);
      }
      final download = await ytdlp.startStreaming(
        videoId,
        outputDir: dir.path,
        title: title,
        onProgress: (pct) {
          if (background) {
            _setBackgroundProgress(videoId, pct);
          } else {
            progress.value = pct;
          }
        },
      );
      _trackDownload(download, videoId, completer);
      if (!completer.isCompleted) completer.complete(download);
    } catch (e) {
      debugPrint('[audio] download FAILED id=$videoId: $e');
      if (!background && downloadingId.value == videoId) {
        downloadingId.value = null;
        progress.value = null;
      } else if (background) {
        _setBackgroundProgress(videoId, null);
      }
      if (identical(_inflight[videoId], completer)) {
        _inflight.remove(videoId);
      }
      if (!completer.isCompleted) completer.completeError(e);
    }
  }

  // Add/update/clear one background download's progress and fire listeners.
  void _setBackgroundProgress(String videoId, double? pct) {
    final map = Map<String, double>.of(backgroundProgress.value);
    if (pct == null) {
      map.remove(videoId);
    } else {
      map[videoId] = pct.clamp(0.0, 1.0);
    }
    backgroundProgress.value = map;
  }

  // Fire-and-forget: applies LRU on completion, cleans up .part on failure.
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
        debugPrint('[audio] download COMPLETE id=$videoId');
        await _enforceLimit(dir);
      } catch (_) {
        debugPrint('[audio] download cleanup id=$videoId (final no generado)');
        _setBackgroundProgress(videoId, null);
        try {
          await _cleanupPartial(dir, videoId);
        } catch (_) {}
      } finally {
        if (identical(_inflight[videoId], completer)) {
          _inflight.remove(videoId);
        }
        if (downloadingId.value == videoId) {
          downloadingId.value = null;
          progress.value = null;
        }
        _setBackgroundProgress(videoId, null);
      }
    }());
  }

  // Removes incomplete .part files for a given videoId.
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

  // Deletes oldest files (LRU) until under the size limit. Runs in isolate.
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
      var evicted = 0;
      for (final f in files) {
        if (total <= limit) return;
        final size = f.statSync().size;
        f.deleteSync();
        total -= size;
        evicted++;
      }
      debugPrint('[audio] LRU: ${total}B descontado tras eliminar '
          '$evicted archivos');
    });
  }

  // VideoIds currently on disk. Runs in isolate.
  Future<Set<String>> cachedIds() async {
    final dir = await cacheDir();
    final dirPath = dir.path;
    return Isolate.run(() {
      final d = Directory(dirPath);
      if (!d.existsSync()) return <String>{};
      return d
          .listSync()
          .whereType<File>()
          .map((f) => p.basenameWithoutExtension(f.path))
          .toSet();
    });
  }

  Future<void> clear() async {
    final dir = await cacheDir();
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }

  // File count and total bytes. Runs in isolate.
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
            } catch (_) {}
          }
        }
      }
      return CacheStats(fileCount: count, bytes: bytes);
    });
  }
}
