import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Resuelve las rutas a los binarios sidecar (yt-dlp + ffmpeg) según la
/// plataforma y el modo de ejecución (desarrollo o empaquetado).
///
/// Orden de búsqueda:
/// 1. Variables de entorno `SCRUP_YTDLP_PATH` / `SCRUP_FFMPEG_PATH` (override).
/// 2. Directorio junto al ejecutable (modo empaquetado).
/// 3. `bin/<plataforma>/` relativo al directorio de trabajo (desarrollo).
class Binaries {
  Binaries._();

  static String get _platformDir {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'windows';
  }

  static String get _exeExt => Platform.isWindows ? '.exe' : '';

  /// Directorio donde buscaremos los binarios, si existe.
  static String? _searchDir() {
    final env = Platform.environment;
    if (env['SCRUP_YTDLP_PATH'] != null && env['SCRUP_YTDLP_PATH']!.isNotEmpty) {
      return p.dirname(env['SCRUP_YTDLP_PATH']!);
    }
    // Modo empaquetado: los binarios van junto al .exe
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      if (File(p.join(exeDir, 'yt-dlp$_exeExt')).existsSync()) {
        return exeDir;
      }
    } catch (_) {}
    // Desarrollo: relativo al CWD del proyecto
    final dev = p.join(Directory.current.path, 'bin', _platformDir);
    if (File(p.join(dev, 'yt-dlp$_exeExt')).existsSync()) {
      return dev;
    }
    // Desarrollo desde otros CWDs: prueba sobre el árbol de archivos fuente
    return null;
  }

  static String? _ytdlpPath;
  static String? _ffmpegPath;

  static String? get ytdlpPath {
    if (_ytdlpPath != null) return _ytdlpPath;
    final env = Platform.environment['SCRUP_YTDLP_PATH'];
    if (env != null && env.isNotEmpty) {
      _ytdlpPath = env;
      return _ytdlpPath;
    }
    final dir = _searchDir();
    if (dir != null) {
      final candidate = p.join(dir, 'yt-dlp$_exeExt');
      if (File(candidate).existsSync()) {
        _ytdlpPath = candidate;
        return _ytdlpPath;
      }
    }
    // Fallback: buscar en PATH
    final inPath = _which('yt-dlp');
    if (inPath != null) {
      _ytdlpPath = inPath;
      return _ytdlpPath;
    }
    return null;
  }

  static String? get ffmpegPath {
    if (_ffmpegPath != null) return _ffmpegPath;
    final env = Platform.environment['SCRUP_FFMPEG_PATH'];
    if (env != null && env.isNotEmpty) {
      _ffmpegPath = env;
      return _ffmpegPath;
    }
    final dir = _searchDir();
    if (dir != null) {
      final candidate = p.join(dir, 'ffmpeg', 'ffmpeg$_exeExt');
      if (File(candidate).existsSync()) {
        _ffmpegPath = candidate;
        return _ffmpegPath;
      }
    }
    final inPath = _which('ffmpeg');
    if (inPath != null) {
      _ffmpegPath = inPath;
      return _ffmpegPath;
    }
    return null;
  }

  static String? _which(String name) {
    if (Platform.isWindows) {
      final cmd = Process.runSync('where', [name]);
      if (cmd.exitCode == 0) {
        final lines =
            (cmd.stdout as String).trim().split('\n').where((l) => l.isNotEmpty).toList();
        return lines.isEmpty ? null : lines.first.trim();
      }
      return null;
    }
    final cmd = Process.runSync('which', [name]);
    if (cmd.exitCode == 0) {
      return (cmd.stdout as String).trim().split('\n').first;
    }
    return null;
  }

  /// Descripción del estado de los binarios, útil para la UI.
  static String get statusSummary {
    final yt = ytdlpPath;
    final ff = ffmpegPath;
    final missing = <String>[
      if (yt == null) 'yt-dlp',
      if (ff == null) 'ffmpeg',
    ];
    if (missing.isEmpty) {
      return 'yt-dlp y ffmpeg listos';
    }
    return 'Faltan: ${missing.join(', ')} — ejecuta tool/fetch_binaries.sh';
  }

  static void logBinaries() {
    debugPrint('[Scrup] yt-dlp  -> ${ytdlpPath ?? "NO ENCONTRADO"}');
    debugPrint('[Scrup] ffmpeg  -> ${ffmpegPath ?? "NO ENCONTRADO"}');
  }
}
