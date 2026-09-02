import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/binaries.dart';
import '../core/track.dart';
import 'ytmusic_service.dart';

class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  @override
  String toString() => message;
}

// Retries on file sharing violations (e.g. Windows Defender scanning).
Future<T> _retryOnSharingViolation<T>(
  Future<T> Function() fn, {
  int maxRetries = 3,
  Duration delay = const Duration(seconds: 2),
}) async {
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt < maxRetries && _isSharingViolation(e)) {
        debugPrint(
          '[yt-dlp] File locked (attempt ${attempt + 1}/$maxRetries), '
          'retrying in ${delay.inSeconds}s...',
        );
        await Future<void>.delayed(delay);
        continue;
      }
      rethrow;
    }
  }
  throw StateError('unreachable');
}

bool _isSharingViolation(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('sharing violation') ||
      msg.contains('being used by another process') ||
      msg.contains('process_win.cc');
}

// In-progress streaming download. The .part file grows while downloading.
class StreamingDownload {
  final Future<String> playablePath;
  final Future<String> finalPath;
  final void Function() cancel;

  StreamingDownload({
    required this.playablePath,
    required this.finalPath,
    required this.cancel,
  });
}

/// Orchestrates yt-dlp for search and download (streaming or full).
class YtDlpService {
  static const int _searchCacheMax = 20;

  static const Duration _searchCacheTtl = Duration(minutes: 5);

  // Canal JNI (MainActivity) que ejecuta yt-dlp embebido en el proceso vía
  // libpython (libscrup_python.so, jniLibs -> SELinux apk_data_file). Se usa
  // en Android en lugar de Process.run/start.
  static const MethodChannel _androidChannel =
      MethodChannel('com.scrup.music.toolchain');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Caché LRU en memoria de búsquedas recientes (clave = `query|limit`).
  final Map<String, _SearchCacheEntry> _searchCache = {};

  // Dedup concurrent searches by key.
  final Map<String, Future<List<Track>>> _searchInflight = {};

  /// Argumentos comunes para descargar el mejor audio de una pista.
  List<String> _downloadArgs(String videoId, String outputDir) {
    final args = <String>[
      '--no-playlist',
      '--no-warnings',
      '--newline',
      '--no-mtime',
      '-f',
      _isAndroid ? 'best' : 'bestaudio/best',
      '-o',
      p.join(outputDir, '%(id)s.%(ext)s'),
      '--print',
      'after_move:filepath',
      'https://www.youtube.com/watch?v=$videoId',
    ];
    if (_isAndroid) {
      args.add('--no-check-certificates');
      final cookies = Binaries.cookiesPath;
      if (cookies != null) {
        args.add('--cookies');
        args.add(cookies);
      }
    }
    return args;
  }

  // En Android el "binario" yt-dlp es el python3 de la toolchain y el script
  // yt-dlp viaja como primer argumento (zipapp). En el resto de plataformas
  // se ejecuta el ejecutable directamente.
  List<String> _launcher(String ytdlpExe) {
    final script = Binaries.ytDlpScript;
    if (script != null) return [ytdlpExe, script];
    return [ytdlpExe];
  }

  // Environment with sidecar binary dirs added to PATH.
  Map<String, String> _envWithSidecars() {
    final env = {
      ...Platform.environment,
      // Android: LD_LIBRARY_PATH/PYTHONHOME para el python3 embebido.
      ...Binaries.androidToolchainEnv(),
    };
    final dirs = Binaries.pathDirs;
    if (dirs.isEmpty) return env;
    final sep = Platform.isWindows ? ';' : ':';
    final path = env['PATH'] ?? '';
    env['PATH'] = '${dirs.join(sep)}$sep$path';
    return env;
  }

  // Runs yt-dlp on Android via JNI (embedded libpython).
  // Output goes to a log file; Kotlin reads it back with the exit code.
  Future<ProcessResult> _runJni(
    List<String> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final ready = await Binaries.ensureAndroidToolchain();
    if (!ready) {
      throw YtDlpException(
        'yt-dlp toolchain not available. Check that the Android build '
        'includes the correct ABI assets.',
      );
    }
    debugPrint('[yt-dlp] jni ${args.join(' ')}');
    final logPath = await _jniLogPath();
    try {
      final res = await _androidChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'ytDlpRun',
            {'args': args, 'logPath': logPath},
          )
          .timeout(timeout);
      final exitCode = (res?['exitCode'] as num?)?.toInt() ?? 1;
      final output = (res?['output'] as String?) ?? '';
      if (exitCode != 0) {
        final err = output.trim();
        debugPrint('[yt-dlp] jni failed (exit=$exitCode): '
            '${err.substring(0, err.length.clamp(0, 500))}');
        throw YtDlpException(err.isNotEmpty ? err : 'yt-dlp error');
      }
      return ProcessResult(0, exitCode, output, '');
    } on TimeoutException {
      await _jniCancel();
      throw YtDlpException('yt-dlp timed out.');
    } catch (e) {
      debugPrint('[yt-dlp] jni exception: $e');
      rethrow;
    }
  }

  Future<String> _jniLogPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'scrup_ytdlp_run.log');
  }

  Future<void> _jniCancel() async {
    try {
      await _androidChannel.invokeMethod<void>('ytDlpCancel');
    } catch (_) {}
  }

  Future<File?> _findPartial(String dir, String videoId) async {
    final d = Directory(dir);
    if (!await d.exists()) return null;
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    for (final f in files) {
      final name = p.basename(f.path);
      if (name.startsWith('$videoId.') && name.endsWith('.part')) return f;
    }
    return null;
  }

  Future<String?> _findFinal(String dir, String videoId) async {
    final d = Directory(dir);
    if (!await d.exists()) return null;
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    for (final f in files) {
      final name = p.basename(f.path);
      if (name.startsWith('$videoId.') && !name.endsWith('.part')) {
        return f.path;
      }
    }
    return null;
  }

  // Runs yt-dlp, returns stdout or throws YtDlpException.
  Future<ProcessResult> _run(
    List<String> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_isAndroid) {
      return _runJni(args, timeout: timeout);
    }
    final ytdlp = await Binaries.resolveYtDlp();
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    final launcher = _launcher(ytdlp);
    final executable = launcher.first;
    final script = launcher.length > 1 ? launcher[1] : null;
    final processArgs = script != null ? [script, ...args] : [...launcher.sublist(1), ...args];
    debugPrint('[yt-dlp] $executable ${processArgs.join(' ')}');
    final result = await _retryOnSharingViolation(
      () => Process.run(
        executable,
        processArgs,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _envWithSidecars(),
      ).timeout(timeout),
    );

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      final out = (result.stdout as String).trim();
      throw YtDlpException(
        err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Error de yt-dlp'),
      );
    }
    return result;
  }

  // Searches YouTube. Results are cached in-memory (LRU + TTL).
  Future<List<Track>> search(String query, {int limit = 10}) async {
    if (query.trim().isEmpty) return const [];

    final key = '$query|$limit';
    final cached = _searchCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _searchCacheTtl) {
      return cached.tracks;
    }

    final inflight = _searchInflight[key];
    if (inflight != null) return inflight;

    final future = _doSearch(query, limit);
    _searchInflight[key] = future;
    try {
      final tracks = await future;
      if (tracks.isNotEmpty) {
        if (_searchCache.length >= _searchCacheMax) {
          String? oldestKey;
          DateTime? oldestAt;
          for (final e in _searchCache.entries) {
            if (oldestAt == null || e.value.at.isBefore(oldestAt)) {
              oldestAt = e.value.at;
              oldestKey = e.key;
            }
          }
          if (oldestKey != null) _searchCache.remove(oldestKey);
        }
        _searchCache[key] = _SearchCacheEntry(tracks, DateTime.now());
      }
      return tracks;
    } finally {
      _searchInflight.remove(key);
    }
  }

  Future<List<Track>> _doSearch(String query, int limit) async {
    final args = <String>[
      'ytsearch$limit:$query',
      '--flat-playlist',
      '--no-warnings',
      '--skip-download',
      '-J',
    ];
    if (_isAndroid) {
      args.add('--no-check-certificates');
      final cookies = Binaries.cookiesPath;
      if (cookies != null) {
        args.add('--cookies');
        args.add(cookies);
      }
    }
    final result = await _run(args);

    final Map<String, dynamic> json;
    try {
      // On Android stdout and stderr are merged into one log file.
      // Strip any lines that don't look like JSON before parsing.
      final raw = result.stdout as String;
      final jsonStart = raw.indexOf('{');
      final cleaned = jsonStart >= 0 ? raw.substring(jsonStart) : raw;
      json = jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[yt-dlp] search parse failed: ${result.stdout}');
      throw YtDlpException('No se pudo interpretar la respuesta de yt-dlp.');
    }

    final entries = json['entries'] as List<dynamic>? ?? [];
    final tracks = <Track>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['id'] == null) continue;
      tracks.add(Track.fromYtDlp(entry));
    }
    return tracks;
  }

  // Starts streaming download. Resolves once the .part is playable.
  // Kills process after 10min timeout to prevent slot deadlock.
  Future<StreamingDownload> startStreaming(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    if (_isAndroid) {
      return _startStreamingAndroid(
        videoId,
        outputDir: outputDir,
        title: title,
        onProgress: onProgress,
      );
    }
    final ytdlp = await Binaries.resolveYtDlp();
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    debugPrint('[yt-dlp] stream $videoId');
    final launcher = _launcher(ytdlp);
    final executable = launcher.first;
    final script = launcher.length > 1 ? launcher[1] : null;
    final processArgs = script != null ? [script, ..._downloadArgs(videoId, outputDir)] : [...launcher.sublist(1), ..._downloadArgs(videoId, outputDir)];
    final process = await _retryOnSharingViolation(
      () => Process.start(
        executable,
        processArgs,
        environment: _envWithSidecars(),
      ),
    );

    final started = DateTime.now();
    final progressRe = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
    final destinationRe = RegExp(r'\[download\]\s+Destination:\s+(.+)$');
    final partialCompleter = Completer<String>();
    final doneCompleter = Completer<String>();
    var stderr = '';
    var printedPath = '';
    var destinationPath = '';
    var processExited = false;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = progressRe.firstMatch(line);
          if (m != null) {
            onProgress?.call(double.parse(m.group(1)!) / 100);
          }
          final dm = destinationRe.firstMatch(line);
          if (dm != null) {
            destinationPath = dm.group(1)!.trim();
          }
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.contains('[download]')) {
            printedPath = trimmed;
          }
        });
    process.stderr.transform(utf8.decoder).listen((chunk) => stderr += chunk);

    // Polls .part file until playable.
    Future<void> pollPartial() async {
      const minBytes = 1024 * 1024;
      const timeout = Duration(seconds: 20);
      final deadline = started.add(timeout);
      var known = destinationPath;
      while (DateTime.now().isBefore(deadline)) {
        if (processExited) return;
        if (known.isEmpty) known = destinationPath;
        if (known.isNotEmpty) {
          final f = File(known);
          if (await f.exists()) {
            final size = await f.length();
            final elapsedMs = DateTime.now().difference(started).inMilliseconds;
            if (size >= minBytes || (elapsedMs >= 6000 && size >= 64 * 1024)) {
              if (!partialCompleter.isCompleted) {
                partialCompleter.complete(known);
              }
              return;
            }
          } else {
            final finalPath = await _findFinal(outputDir, videoId);
            if (finalPath != null) {
              if (!partialCompleter.isCompleted) {
                partialCompleter.complete(finalPath);
              }
              return;
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      String? partialPath = known.isNotEmpty && await File(known).exists()
          ? known
          : null;
      if (partialPath == null) {
        final partial = await _findPartial(outputDir, videoId);
        partialPath = partial?.path;
      }
      if (partialPath != null) {
        if (!partialCompleter.isCompleted) {
          partialCompleter.complete(partialPath);
        }
      } else if (!partialCompleter.isCompleted) {
        partialCompleter.completeError(
          YtDlpException(
            'La descarga de "${title ?? videoId}" no generó datos '
            'reproducibles.',
          ),
        );
      }
    }

    unawaited(pollPartial());

    // Wait for process with timeout to avoid deadlock.
    unawaited(() async {
      int code;
      try {
        code = await process.exitCode.timeout(const Duration(minutes: 10));
      } on TimeoutException {
        process.kill();
        final err = 'La descarga de "${title ?? videoId}" tardó demasiado.';
        onProgress?.call(null);
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(YtDlpException(err));
        }
        if (!partialCompleter.isCompleted) {
          partialCompleter.completeError(YtDlpException(err));
        }
        return;
      }
      processExited = true;
      if (code == 0) {
        String? finalPath;
        if (printedPath.isNotEmpty && File(printedPath).existsSync()) {
          finalPath = printedPath;
        } else {
          finalPath = await _findFinal(outputDir, videoId);
        }
        if (finalPath == null) {
          final err =
              'La descarga de "${title ?? videoId}" no produjo '
              'un archivo.';
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(YtDlpException(err));
          }
          if (!partialCompleter.isCompleted) {
            partialCompleter.completeError(YtDlpException(err));
          }
        } else {
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete(finalPath);
          }
          if (!partialCompleter.isCompleted) {
            partialCompleter.complete(finalPath);
          }
        }
      } else {
        final err = stderr.trim().isNotEmpty
            ? stderr.trim()
            : 'No se pudo descargar "${title ?? videoId}".';
        onProgress?.call(null);
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(YtDlpException(err));
        }
        if (!partialCompleter.isCompleted) {
          partialCompleter.completeError(YtDlpException(err));
        }
      }
    }());

    return StreamingDownload(
      playablePath: partialCompleter.future,
      finalPath: doneCompleter.future,
      cancel: process.kill,
    );
  }

  // Streaming on Android: try yt-dlp first, fallback to InnerTube HTTP.
  Future<StreamingDownload> _startStreamingAndroid(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    await Binaries.ensureAndroidToolchain();
    debugPrint('[yt-dlp] stream(jni) $videoId');

    // Try yt-dlp first; on failure fall back to InnerTube HTTP download.
    try {
      final result = await _run(
        _downloadArgs(videoId, outputDir),
        timeout: const Duration(minutes: 3),
      );
      final path = (result.stdout as String).trim();
      if (path.isNotEmpty && await File(path).exists()) {
        return StreamingDownload(
          playablePath: Future.value(path),
          finalPath: Future.value(path),
          cancel: () {},
        );
      }
    } catch (e) {
      debugPrint('[yt-dlp] jni streaming failed, trying InnerTube: $e');
    }

    // InnerTube HTTP fallback.
    return _startStreamingInnerTube(
      videoId,
      outputDir: outputDir,
      title: title,
      onProgress: onProgress,
    );
  }

  // InnerTube HTTP streaming fallback for Android.
  // Gets audio URL from InnerTube player endpoint and downloads via HTTP.
  Future<StreamingDownload> _startStreamingInnerTube(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    debugPrint('[innertube] stream $videoId');
    final doneCompleter = Completer<String>();
    final partialCompleter = Completer<String>();
    var cancelled = false;

    unawaited(() async {
      try {
        final url = await YtMusicService().getAudioStreamUrl(videoId);
        if (url == null) {
          throw YtDlpException('InnerTube no devolvió URL de audio para $videoId');
        }
        debugPrint('[innertube] got audio URL, downloading...');
        // Download to .part first, rename on completion.
        final outputPath = p.join(outputDir, '$videoId.webm');
        final partialPath = '$outputPath.part';
        final req = await HttpClient().getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw YtDlpException('HTTP ${res.statusCode} downloading audio');
        }
        final totalLen = res.contentLength;
        var received = 0;
        final sink = File(partialPath).openWrite();
        await for (final chunk in res) {
          if (cancelled) {
            await sink.close();
            try { File(partialPath).deleteSync(); } catch (_) {}
            return;
          }
          sink.add(chunk);
          received += chunk.length;
          if (!partialCompleter.isCompleted &&
              (received >= 1024 * 1024 ||
               (totalLen > 0 && received >= totalLen))) {
            partialCompleter.complete(partialPath);
          }
          if (totalLen > 0) {
            onProgress?.call(received / totalLen);
          }
        }
        await sink.close();
        // Rename .part to final.
        File(partialPath).renameSync(outputPath);
        if (!doneCompleter.isCompleted) doneCompleter.complete(outputPath);
        if (!partialCompleter.isCompleted) partialCompleter.complete(outputPath);
      } catch (e) {
        debugPrint('[innertube] stream error: $e');
        final msg = e is YtDlpException ? e.message : '$e';
        if (!doneCompleter.isCompleted) doneCompleter.completeError(YtDlpException(msg));
        if (!partialCompleter.isCompleted) partialCompleter.completeError(YtDlpException(msg));
      }
    }());

    return StreamingDownload(
      playablePath: partialCompleter.future,
      finalPath: doneCompleter.future,
      cancel: () { cancelled = true; },
    );
  }

  // Extracts full track metadata. Uses android client (~20% faster
  // than web for metadata only). Don't use for downloads.
  Future<Track?> getTrackInfo(String videoId) async {
    final result = await _run([
      '--no-playlist',
      '--no-warnings',
      '--skip-download',
      '--extractor-args',
      'youtube:player_client=android',
      '-J',
      'https://www.youtube.com/watch?v=$videoId',
    ]);
    try {
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      return Track.fromYtDlp(json);
    } catch (_) {
      return null;
    }
  }
}

class _SearchCacheEntry {
  final List<Track> tracks;
  final DateTime at;

  const _SearchCacheEntry(this.tracks, this.at);
}
