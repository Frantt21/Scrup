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

// Log SIEMPRE visible (debug y release): cada etapa de la búsqueda,
// descarga y streaming de yt-dlp con millis desde el arranque del proceso
// (facilita correlacionar con `adb logcat -d | grep yt-dlp`). Independiente
// de kPaletteLog (ese flag apaga los SCPR de paleta/UI, no estos).
final DateTime _ytdlpBoot = DateTime.now();
void _ytLog(String msg) {
  final ms = DateTime.now().difference(_ytdlpBoot).inMilliseconds;
  debugPrint('[yt-dlp +${ms}ms] $msg');
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
    bool throwOnFail = true,
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
    final t0 = DateTime.now();
    try {
      final res = await _androidChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'ytDlpRun',
            {'args': args, 'logPath': logPath},
          )
          .timeout(timeout);
      final exitCode = (res?['exitCode'] as num?)?.toInt() ?? 1;
      final output = (res?['output'] as String?) ?? '';
      final elapsedMs = DateTime.now().difference(t0).inMilliseconds;
      if (exitCode != 0 && throwOnFail) {
        final err = output.trim();
        _ytLog('jni exit=$exitCode after ${elapsedMs}ms '
            '${err.substring(0, err.length.clamp(0, 500))}');
        throw YtDlpException(err.isNotEmpty ? err : 'yt-dlp error');
      }
      if (exitCode != 0) {
        _ytLog('jni exit=$exitCode (tolerado) after ${elapsedMs}ms');
      }
      _ytLog('jni ok exit=0 after ${elapsedMs}ms '
          '(out ${output.length} chars)');
      return ProcessResult(0, exitCode, output, '');
    } on TimeoutException {
      _ytLog('jni TIMEOUT after ${timeout.inSeconds}s, cancelando');
      await _jniCancel();
      throw YtDlpException('yt-dlp timed out.');
    } catch (e) {
      _ytLog('jni exception: $e');
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
    bool throwOnFail = true,
  }) async {
    if (_isAndroid) {
      return _runJni(
        args,
        timeout: timeout,
        throwOnFail: throwOnFail,
      );
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
    final t0 = DateTime.now();
    final result = await _retryOnSharingViolation(
      () => Process.run(
        executable,
        processArgs,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _envWithSidecars(),
      ).timeout(timeout),
    );
    final elapsedMs = DateTime.now().difference(t0).inMilliseconds;

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      final out = (result.stdout as String).trim();
      _ytLog('run FAILED exit=${result.exitCode} after ${elapsedMs}ms: '
          '${(err.isNotEmpty ? err : out).substring(0, ((err.isNotEmpty ? err : out).length).clamp(0, 500))}');
      throw YtDlpException(
        err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Error de yt-dlp'),
      );
    }
    _ytLog('run ok exit=0 after ${elapsedMs}ms '
        '(out ${(result.stdout as String).length} chars)');
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
    final started = DateTime.now();
    _ytLog('stream start id=$videoId title=${title ?? '-'}');
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
    _ytLog('stream pid=${process.pid} started');

    final progressRe = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
    final destinationRe = RegExp(r'\[download\]\s+Destination:\s+(.+)$');
    final partialCompleter = Completer<String>();
    final doneCompleter = Completer<String>();
    var stderr = '';
    var printedPath = '';
    var destinationPath = '';
    var processExited = false;
    var lastLoggedPct = -1.0;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = progressRe.firstMatch(line);
          if (m != null) {
            final pct = double.parse(m.group(1)!) / 100;
            onProgress?.call(pct);
            // Log cada ~10% (sin spam: el texto completo lo imprime yt-dlp).
            if (pct - lastLoggedPct >= 0.099) {
              lastLoggedPct = pct;
              _ytLog('stream id=$videoId ${(pct * 100).round()}%');
            }
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
                _ytLog(
                  'stream id=$videoId PARTIAL reproducible '
                  '+${elapsedMs}ms (${size}B) -> $known',
                );
                partialCompleter.complete(known);
              }
              return;
            }
          } else {
            final finalPath = await _findFinal(outputDir, videoId);
            if (finalPath != null) {
              if (!partialCompleter.isCompleted) {
                _ytLog(
                  'stream id=$videoId PARTIAL via final file '
                  '($finalPath)',
                );
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
        _ytLog('stream id=$videoId TIMEOUT 10min, proceso matado');
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
        _ytLog(
          'stream id=$videoId exit=0 +${DateTime.now().difference(started).inMilliseconds}ms '
          'final=${finalPath ?? 'NULL'}',
        );
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
        _ytLog('stream id=$videoId FAILED exit=$code: '
            '${err.substring(0, err.length.clamp(0, 400))}');
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

  // Streaming on Android. From this pipeline every audio-only route (WEB,
  // tv, android_vr, InnerTube/WEB_REMIX) ends in googlevideo 403: YouTube
  // PO-token-gates those formats. The MUXED format is NOT gated, so two
  // muxed resolvers race: an InnerTube muxed URL (one HTTPS POST, ~300ms)
  // beats yt-dlp's ~9s python boot. Both go through the 1-byte range probe
  // so a dead URL never reaches the player, and the resolved-URL cache
  // short-circuits everything when the track was pre-resolved by a search.
  Future<StreamingDownload> _startStreamingAndroid(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    _ytLog('stream(android) start id=$videoId title=${title ?? '-'}');

    final ytdlpUrlF = _androidGetUrl(videoId);
    final innertubeF = _innertubeMuxedValidatedUrl(videoId);

    String? streamUrl;
    try {
      streamUrl = await innertubeF.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
      if (streamUrl != null) {
        _ytLog('stream(android) id=$videoId innertube muxed URL ok');
      }
    } catch (_) {}
    final bool fromInnertube = streamUrl != null;

    // InnerTube sin URL (o caído): la extracción de yt-dlp. PERO si ese
    // get-url se está sirviendo de un presolve BATCH en curso (espera por
    // lote), no bloquear detrás de las 12 URLs del lote: esperar como máximo
    // [_presolveJoinWait] y si no llegó, extraer SOLO este vídeo en paralelo
    // (una URL llega mucho antes que el lote completo).
    if (!fromInnertube) {
      streamUrl = await ytdlpUrlF.timeout(
        _presolveJoinWait,
        onTimeout: () => _doAndroidGetUrl(videoId),
      );
    }
    if (streamUrl == null) {
      _ytLog('stream(android) id=$videoId sin URL');
      throw YtDlpException(
        'No se pudo obtener la URL de audio de "${title ?? videoId}".',
      );
    }

    return _streamHttp(
      streamUrl,
      videoId,
      outputDir: outputDir,
      title: title,
      fromInnertube: fromInnertube,
      onProgress: onProgress,
    );
  }

  /// Cuánto espera el primer play a un presolve batch en curso antes de
  /// extraer por su cuenta. El lote (python boot + N URLs) tarda bastante
  /// más que una extracción individual; esperar completo era parte de los
  /// 9-10s percibidos en el primer play.
  static const Duration _presolveJoinWait = Duration(seconds: 4);

  // InnerTube ANDROID-client MUXED URL (www.youtube.com — serves any video,
  // unlike the music endpoint) accepted only if it passes the range probe.
  // Not PO-token gated; ~300ms. Fast path for the first play.
  Future<String?> _innertubeMuxedValidatedUrl(String videoId) async {
    try {
      final yt = YtMusicService();
      final u =
          await yt.getAndroidMuxedStreamUrl(videoId) ??
          // Music-catalog tracks: WEB_REMIX muxed as second try.
          await yt.getMuxedStreamUrl(videoId);
      if (u == null) return null;
      if (await _urlAcceptsRange(u)) {
        _cacheResolvedUrl(videoId, u);
        return u;
      }
      _ytLog('stream(android) id=$videoId innertube muxed rechazada');
    } catch (e) {
      _ytLog('stream(android) id=$videoId innertube muxed FAILED: $e');
    }
    return null;
  }

  // Range GET (bytes=0-0) probe: 200/206 means the URL is alive. Costs one
  // tiny request and saves the player from a 403 on throttled/expired URLs.
  static Future<bool> _urlAcceptsRange(String url) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close();
      final ok = res.statusCode == 200 || res.statusCode == 206;
      await res.drain<void>();
      return ok;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  // Downloads an audio URL via HTTP with progressive streaming. The partial
  // file is playable as soon as ~1MB arrives; if the download FAILS before
  // playback started it retries once with a URL from the OTHER resolver
  // (validated before use), since either URL can be throttled or expired.
  Future<StreamingDownload> _streamHttp(
    String url,
    String videoId, {
    required String outputDir,
    required bool fromInnertube,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    final doneCompleter = Completer<String>();
    final partialCompleter = Completer<String>();
    var cancelled = false;
    final started = DateTime.now();
    final outputPath = p.join(outputDir, '$videoId.webm');
    final partialPath = '$outputPath.part';

    // Single body for one download attempt. Returns true on success.
    Future<bool> attempt(String dlUrl) async {
      _ytLog('http start id=$videoId (${dlUrl.length} chars url)');
      final req = await HttpClient().getUrl(Uri.parse(dlUrl));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw YtDlpException('HTTP ${res.statusCode} streaming audio');
      }
      final totalLen = res.contentLength;
      _ytLog('http id=$videoId status=${res.statusCode} len=$totalLen');
      var received = 0;
      final sink = File(partialPath).openWrite();
      try {
        await for (final chunk in res) {
          if (cancelled) {
            _ytLog('http id=$videoId CANCELADO (${received}B)');
            return true; // handled by cancel(); do NOT retry
          }
          sink.add(chunk);
          received += chunk.length;
          // Complete partial after 1MB or 6s — enough for playback to start.
          final elapsedMs = DateTime.now().difference(started).inMilliseconds;
          if (!partialCompleter.isCompleted &&
              (received >= 1024 * 1024 ||
               (elapsedMs >= 6000 && received >= 64 * 1024))) {
            _ytLog('http id=$videoId PARTIAL +${elapsedMs}ms (${received}B)');
            partialCompleter.complete(partialPath);
          }
          if (totalLen > 0) {
            onProgress?.call(received / totalLen);
          }
        }
      } finally {
        await sink.close();
      }
      File(partialPath).renameSync(outputPath);
      if (!doneCompleter.isCompleted) doneCompleter.complete(outputPath);
      if (!partialCompleter.isCompleted) partialCompleter.complete(outputPath);
      _ytLog('http id=$videoId done ${received}B -> $outputPath');
      return true;
    }

    unawaited(() async {
      try {
        try {
          await attempt(url);
          return;
        } catch (e) {
          if (cancelled || partialCompleter.isCompleted) rethrow;
          _ytLog('http id=$videoId attempt 1 failed: $e');
        }
        // Retry: a validated InnerTube URL, else a fresh muxed extraction
        // (URLs expire/throttle; a second muxed request usually works).
        _ytLog('http id=$videoId retry con URL alternativa');
        String? alt;
        if (fromInnertube) {
          alt = await _androidGetUrl(videoId);
        } else {
          alt = await _innertubeMuxedValidatedUrl(videoId);
        }
        if (alt == null || alt == url) {
          // The cached URL 403'd before expiry: drop it and re-extract.
          _resolvedUrls.remove(videoId);
          alt = await _androidGetUrl(videoId);
        }
        if (alt == null || alt == url) {
          throw YtDlpException('streaming audio sin URL de reintento');
        }
        await attempt(alt);
      } catch (e) {
        _ytLog('http id=$videoId ERROR: $e');
        final msg = e is YtDlpException ? e.message : '$e';
        try {
          if (File(partialPath).existsSync()) File(partialPath).deleteSync();
        } catch (_) {}
        if (!doneCompleter.isCompleted) doneCompleter.completeError(YtDlpException(msg));
        if (!partialCompleter.isCompleted) partialCompleter.completeError(YtDlpException(msg));
      }
    }());

    return StreamingDownload(
      playablePath: partialCompleter.future,
      finalPath: doneCompleter.future,
      cancel: () {
        cancelled = true;
        try {
          File(partialPath).deleteSync();
        } catch (_) {}
      },
    );
  }

  // ── Resolved-URL cache (Android first-play fast path) ──────────────────
  // A googlevideo muxed URL stays valid for ~6h. Caching them turns the
  // FIRST play of an already-searched track into a pure HTTP download
  // (~1-2s) instead of a python boot + extraction (~9s). Persisted to disk:
  // URLs resolved in PREVIOUS sessions still hit (searching yesterday must
  // not pay extraction again today).
  static const Duration _resolvedUrlTtl = Duration(hours: 5);

  // videoId -> (url, resolvedAt, muxed). STATIC: SearchService, PlayerService
  // y los presets comparten la misma caché entre instancias.
  static final Map<String, (String, DateTime, bool)> _resolvedUrls = {};

  static File? _urlCacheFile;
  static bool _urlCacheLoaded = false;
  static Timer? _urlCacheFlush;
  static bool _urlCacheDirty = false;

  static Future<File?> _urlCachePath() async {
    if (_urlCacheFile != null) return _urlCacheFile;
    try {
      final base = await getApplicationSupportDirectory();
      _urlCacheFile = File(p.join(base.path, 'resolved_urls.json'));
    } catch (_) {}
    return _urlCacheFile;
  }

  static Future<void> _loadUrlCache() async {
    if (_urlCacheLoaded) return;
    _urlCacheLoaded = true;
    try {
      final f = await _urlCachePath();
      if (f == null || !await f.exists()) return;
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final now = DateTime.now();
      raw.forEach((id, v) {
        if (v is! Map<String, dynamic>) return;
        final at = DateTime.tryParse(v['at'] as String? ?? '');
        final url = v['url'] as String?;
        if (at == null || url == null) return;
        if (now.difference(at) > _resolvedUrlTtl) return;
        _resolvedUrls[id] = (url, at, true);
      });
      _ytLog('urlcache loaded: ${_resolvedUrls.length} entradas');
    } catch (_) {}
  }

  // Debounced flush (1s): batches rapid multi-resolve bursts into one write.
  static void _scheduleUrlCacheFlush() {
    _urlCacheDirty = true;
    _urlCacheFlush ??= Timer(const Duration(seconds: 1), () async {
      _urlCacheFlush = null;
      if (!_urlCacheDirty) return;
      _urlCacheDirty = false;
      try {
        final f = await _urlCachePath();
        if (f == null) return;
        final now = DateTime.now();
        final map = {
          for (final e in _resolvedUrls.entries)
            if (now.difference(e.value.$2) <= _resolvedUrlTtl)
              e.key: {'url': e.value.$1, 'at': e.value.$2.toIso8601String()},
        };
        await f.writeAsString(jsonEncode(map), flush: true);
      } catch (_) {}
    });
  }

  // Dedupes concurrent single extractions of the same video.
  static final Map<String, Future<String?>> _resolveInflight = {};

  // Per-id waiters for an in-flight batch presolve: a first play that lands
  // mid-batch JOINS it instead of booting another python (~9s saved).
  static final Map<String, Completer<String?>> _presolveWaiters = {};

  static String? _cachedResolvedUrl(String videoId) {
    final e = _resolvedUrls[videoId];
    if (e == null) return null;
    if (DateTime.now().difference(e.$2) > _resolvedUrlTtl) {
      _resolvedUrls.remove(videoId);
      return null;
    }
    return e.$1;
  }

  static void _cacheResolvedUrl(String videoId, String url) {
    _resolvedUrls[videoId] = (url, DateTime.now(), true);
    _scheduleUrlCacheFlush();
  }

  /// Batch-resolves streaming URLs for [videoIds] so later plays start
  /// instantly (pure HTTP download). Two layers, both best-effort and
  /// fire-and-forget:
  ///  1. InnerTube muxed URLs — one POST per video in parallel (~300ms).
  ///  2. yt-dlp batch — ONE python run for all pending ids (~9s total).
  /// Only muxed URLs are cached: audio-only formats are PO-token gated.
  Future<void> preResolveUrls(List<String> videoIds) async {
    if (!_isAndroid || videoIds.isEmpty) return;
    await _loadUrlCache();
    final pending = videoIds
        .where(
          (id) =>
              id.isNotEmpty &&
              _cachedResolvedUrl(id) == null &&
              !_presolveWaiters.containsKey(id),
        )
        .take(12)
        .toList();
    if (pending.isEmpty) return;

    final waiters = {for (final id in pending) id: Completer<String?>()};
    _presolveWaiters.addAll(waiters);
    void done(String id, String? url) {
      final w = waiters[id];
      if (w != null && !w.isCompleted) w.complete(url);
    }

    // Layer 1: InnerTube ANDROID-client muxed, parallel (~300ms each).
    unawaited(() async {
      var ok = 0;
      await Future.wait([
        for (final id in pending)
          () async {
            final u = await _innertubeMuxedValidatedUrl(id);
            if (u != null) {
              ok++;
              done(id, u);
            }
          }(),
      ]);
      _ytLog('presolve innertube: $ok/${pending.length} URLs');
    }());      // Layer 2: yt-dlp batch (one python boot for all). yt-dlp exits
      // NONZERO if any single video fails — but stdout still holds the URLs
      // it did resolve. Parse them regardless (throwOnFail: false) so one
      // bad video does not poison the whole batch.
      unawaited(() async {
        var cached = 0;
        try {
          await Binaries.ensureAndroidToolchain();
          final args = <String>[
            '--no-playlist',
            '--no-warnings',
            // Muxed itag 18 first: audio-only formats are PO-token gated and
            // 22 (720p) triples the download for audio nobody hears.
            '-f', '18/best',
            '--get-url',
            '--no-check-certificates',
          ];
          final cookies = Binaries.cookiesPath;
          if (cookies != null) args.addAll(['--cookies', cookies]);
          for (final id in pending) {
            args.add('https://www.youtube.com/watch?v=$id');
          }
          final result = await _run(
            args,
            timeout: const Duration(minutes: 2),
            throwOnFail: false,
          );
          final lines = (result.stdout as String)
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.startsWith('http'))
              .toList();
          final n = lines.length < pending.length
              ? lines.length
              : pending.length;
          final now = DateTime.now();
          for (var i = 0; i < n; i++) {
            if (_cachedResolvedUrl(pending[i]) != null) continue;
            _cacheResolvedUrl(pending[i], lines[i]);
            cached++;
            done(pending[i], lines[i]);
          }
        } catch (e) {
          _ytLog('presolve batch FAILED: $e');
        } finally {
          _ytLog('presolve batch: $cached/${pending.length} URLs');
          for (final id in pending) {
            done(id, _cachedResolvedUrl(id));
            _presolveWaiters.remove(id);
          }
        }
      }());
  }

  // yt-dlp --get-url. Returns the MUXED format (-f best): audio-only formats
  // are PO-token gated (googlevideo answers 403); muxed is not. Cookies are
  // passed when bundled (auth-gated videos). Served from the resolved-URL
  // cache when fresh.
  Future<String?> _androidGetUrl(String videoId) async {
    await _loadUrlCache();
    final cached = _cachedResolvedUrl(videoId);
    if (cached != null) {
      _ytLog('stream(android) id=$videoId URL desde caché');
      return cached;
    }
    // A batch presolve for this id is running: join it instead of booting
    // another python runtime.
    final waiter = _presolveWaiters[videoId];
    if (waiter != null) {
      _ytLog('stream(android) id=$videoId esperando presolve en curso');
      final u = await waiter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => null,
      );
      if (u != null) {
        _ytLog('stream(android) id=$videoId URL desde presolve');
        return u;
      }
    }
    final inflight = _resolveInflight[videoId];
    if (inflight != null) return inflight;
    final f = _doAndroidGetUrl(videoId);
    _resolveInflight[videoId] = f;
    try {
      return await f;
    } finally {
      _resolveInflight.remove(videoId);
    }
  }

  Future<String?> _doAndroidGetUrl(String videoId) async {
    try {
      await Binaries.ensureAndroidToolchain();
      final args = <String>[
        '--no-playlist',
        '--no-warnings',
        // Muxed itag 18 first (audio-only is PO-token gated; 22 is 720p).
        '-f',
        '18/best',
        '--get-url',
        'https://www.youtube.com/watch?v=$videoId',
        '--no-check-certificates',
      ];
      final cookies = Binaries.cookiesPath;
      if (cookies != null) {
        args.addAll(['--cookies', cookies]);
      }
      final result = await _run(args, timeout: const Duration(seconds: 30));
      final url = (result.stdout as String).trim().split('\n').last.trim();
      if (url.startsWith('http')) {
        _cacheResolvedUrl(videoId, url);
        return url;
      }
    } catch (_) {}
    return null;
  }

  // Extracts full track metadata. Uses the android client (~20% faster
  // than web for metadata only). Do not use for downloads.
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
