import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/binaries.dart';
import '../core/track.dart';

/// Excepción de dominio de yt-dlp.
class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  @override
  String toString() => message;
}

/// Descarga en streaming de yt-dlp en curso: el audio se escribe en un
/// archivo `.part` que crece mientras se descarga.
///
/// - [playablePath]: resuelve en cuanto el archivo parcial tiene datos
///   suficientes para empezar a reproducir (sin esperar a que termine).
/// - [finalPath]: resuelve al terminar, con la ruta final ya cacheada
///   (yt-dlp renombra el `.part` al nombre definitivo).
/// - [cancel]: mata el proceso.
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

/// Servicio que orquesta yt-dlp vía subprocesos:
/// - Búsqueda de pistas (`ytsearchN:query`)
/// - Descarga completa o en streaming (reproducir mientras descarga)
class YtDlpService {
  /// Argumentos comunes para descargar el mejor audio de una pista.
  List<String> _downloadArgs(String videoId, String outputDir) {
    return [
      '--no-playlist',
      '--no-warnings',
      '--newline',
      // El mtime debe ser el de la descarga, no la fecha de subida del
      // video, para que la evicción LRU del caché sea correcta.
      '--no-mtime',
      '-f',
      'bestaudio/best',
      '-o',
      p.join(outputDir, '%(id)s.%(ext)s'),
      '--print',
      'after_move:filepath',
      'https://www.youtube.com/watch?v=$videoId',
    ];
  }

  /// Entorno con el directorio de ffmpeg añadido al PATH.
  Map<String, String> _envWithFfmpeg() {
    final env = {...Platform.environment};
    final ffmpeg = Binaries.ffmpegPath;
    if (ffmpeg != null) {
      final sep = Platform.isWindows ? ';' : ':';
      final path = env['PATH'] ?? '';
      env['PATH'] = '${p.dirname(ffmpeg)}$sep$path';
    }
    return env;
  }

  /// Busca en [dir] un archivo parcial (`<videoId>.*.part`) en descarga.
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

  /// Busca en [dir] el archivo final (`<videoId>.*` sin `.part`).
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

  /// Ejecuta yt-dlp y devuelve la salida (stdout) o lanza [YtDlpException].
  Future<ProcessResult> _run(
    List<String> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final ytdlp = Binaries.ytdlpPath;
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    debugPrint('[yt-dlp] ${args.join(' ')}');
    final env = {...Platform.environment};
    final ffmpeg = Binaries.ffmpegPath;
    if (ffmpeg != null) {
      // Añadir el directorio de ffmpeg al PATH para que yt-dlp lo encuentre
      final sep = Platform.isWindows ? ';' : ':';
      final path = env['PATH'] ?? '';
      env['PATH'] = '${p.dirname(ffmpeg)}$sep$path';
    }
    final result = await Process.run(
      ytdlp,
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: env,
    ).timeout(timeout);

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      final out = (result.stdout as String).trim();
      throw YtDlpException(
        err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Error de yt-dlp'),
      );
    }
    return result;
  }

  /// Busca canciones en YouTube. Devuelve lista de [Track].
  Future<List<Track>> search(String query, {int limit = 10}) async {
    if (query.trim().isEmpty) return const [];

    final result = await _run([
      'ytsearch$limit:$query',
      '--flat-playlist',
      '--no-warnings',
      '--skip-download',
      '-J',
    ]);

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    } catch (e) {
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

  /// Descarga en streaming: arranca el proceso y resuelve en cuanto el
  /// archivo `.part` tiene datos suficientes para reproducir (1 MiB, o bien
  /// 6s transcurridos con al menos 64 KiB en conexiones lentas). La descarga
  /// continúa en segundo plano y [StreamingDownload.finalPath] resuelve al
  /// terminar, cuando el `.part` ya se renombró al archivo definitivo.
  ///
  /// Si el proceso se cuelga (red detenida, etc.) se mata a los 10 minutos
  /// para que [StreamingDownload.finalPath] nunca quede sin resolver (un
  /// finalPath colgado bloquearía el slot del caché para siempre).
  Future<StreamingDownload> startStreaming(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    final ytdlp = Binaries.ytdlpPath;
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    debugPrint('[yt-dlp] stream $videoId');
    final process = await Process.start(
      ytdlp,
      _downloadArgs(videoId, outputDir),
      environment: _envWithFfmpeg(),
    );

    final started = DateTime.now();
    final progressRe = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
    final partialCompleter = Completer<String>();
    final doneCompleter = Completer<String>();
    var stderr = '';
    var printedPath = '';
    var processExited = false;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = progressRe.firstMatch(line);
          if (m != null) {
            onProgress?.call(double.parse(m.group(1)!) / 100);
          }
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.contains('[download]')) {
            printedPath = trimmed;
          }
        });
    process.stderr.transform(utf8.decoder).listen((chunk) => stderr += chunk);

    // Vigilar el archivo `.part` hasta que sea reproducible.
    Future<void> pollPartial() async {
      const minBytes = 1024 * 1024;
      const timeout = Duration(seconds: 20);
      final deadline = started.add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (processExited) return;
        final partial = await _findPartial(outputDir, videoId);
        if (partial != null) {
          final size = await partial.length();
          final elapsedMs = DateTime.now().difference(started).inMilliseconds;
          if (size >= minBytes || (elapsedMs >= 6000 && size >= 64 * 1024)) {
            if (!partialCompleter.isCompleted) {
              partialCompleter.complete(partial.path);
            }
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // Timeout: reproducir con lo que haya, o fallar si no hay nada.
      final partial = await _findPartial(outputDir, videoId);
      if (partial != null) {
        if (!partialCompleter.isCompleted) {
          partialCompleter.complete(partial.path);
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

    // Esperar al proceso con un tope: si yt-dlp se cuelga, se mata y se
    // completa con error (nunca dejar un finalPath sin resolver).
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

  /// Extrae metadatos completos de una pista (útil para refrescar el cache).
  Future<Track?> getTrackInfo(String videoId) async {
    final result = await _run([
      '--no-playlist',
      '--no-warnings',
      '--skip-download',
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
