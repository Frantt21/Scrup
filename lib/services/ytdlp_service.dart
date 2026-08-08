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

  /// Extrae la URL directa de audio de una pista SIN descargarla.
  ///
  /// Elige el mejor formato de solo-audio (m4a/opus). Estas URLs expiran,
  /// por lo que SIEMPRE debe llamarse en el momento de reproducir.
  Future<String> getAudioUrl(String videoId, {String? title}) async {
    final result = await _run([
      '--no-playlist',
      '--no-warnings',
      '--skip-download',
      '-f',
      'bestaudio/best',
      '-g',
      'https://www.youtube.com/watch?v=$videoId',
    ]);

    final lines = (result.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw YtDlpException('No se pudo extraer audio de "${title ?? videoId}".');
    }
    return lines.first.trim();
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
