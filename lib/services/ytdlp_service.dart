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

/// Servicio que orquesta yt-dlp vía subprocesos:
/// - Búsqueda de pistas (`ytsearchN:query`)
/// - Extracción de la URL de audio directa (sin descargar el archivo)
class YtDlpService {
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

  /// Descarga el mejor audio de una pista a [outputDir] y devuelve la ruta
  /// local del archivo. El nombre final es `<videoId>.<ext>`.
  ///
  /// Lee la salida en vivo para notificar el progreso (0.0–1.0) vía
  /// [onProgress], y usa `--print after_move:filepath` para obtener la ruta
  /// exacta que escribió yt-dlp (el formato puede variar entre m4a/opus/webm).
  Future<String> downloadAudio(
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

    final env = {...Platform.environment};
    final ffmpeg = Binaries.ffmpegPath;
    if (ffmpeg != null) {
      final sep = Platform.isWindows ? ';' : ':';
      final path = env['PATH'] ?? '';
      env['PATH'] = '${p.dirname(ffmpeg)}$sep$path';
    }

    debugPrint('[yt-dlp] download $videoId');
    final process = await Process.start(
      ytdlp,
      [
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
      ],
      environment: env,
    );

    // Parseo en vivo: progreso `[download] xx.x%` y ruta final del archivo.
    final progressRe = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
    var stderr = '';
    var printedPath = '';
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

    int exitCode;
    try {
      exitCode = await process.exitCode
          .timeout(const Duration(minutes: 10));
    } on TimeoutException {
      process.kill();
      throw YtDlpException(
        'La descarga de "${title ?? videoId}" tardó demasiado.',
      );
    }

    if (exitCode != 0) {
      onProgress?.call(null);
      throw YtDlpException(
        stderr.trim().isNotEmpty
            ? stderr.trim()
            : 'No se pudo descargar "${title ?? videoId}".',
      );
    }

    // Ruta final: primero la impresa por `--print`, con fallback a escanear
    // el directorio por `<videoId>.*` (robusto ante cambios de formato).
    String? filePath;
    if (printedPath.isNotEmpty && File(printedPath).existsSync()) {
      filePath = printedPath;
    } else {
      final dir = Directory(outputDir);
      if (await dir.exists()) {
        final files = await dir
            .list()
            .where((e) =>
                e is File &&
                p.basename(e.path).startsWith('$videoId.') &&
                !p.basename(e.path).endsWith('.part'))
            .cast<File>()
            .toList();
        if (files.isNotEmpty) filePath = files.first.path;
      }
    }
    if (filePath == null) {
      onProgress?.call(null);
      throw YtDlpException(
        'La descarga de "${title ?? videoId}" no produjo un archivo.',
      );
    }
    onProgress?.call(1.0);
    return filePath;
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
