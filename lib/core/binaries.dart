import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Resuelve las rutas a los binarios sidecar (yt-dlp + ffmpeg) según la
/// plataforma y el modo de ejecución (desarrollo o empaquetado).
///
/// Orden de búsqueda:
/// 1. Variables de entorno `SCRUP_YTDLP_PATH` / `SCRUP_FFMPEG_PATH` (override).
/// 2. Directorio `<exeDir>/tools/` (modo empaquetado, nuevo).
/// 3. Directorio junto al ejecutable (legacy).
/// 4. `bin/<plataforma>/` relativo al directorio de trabajo (desarrollo).
class BinaryDownloadStatus {
  const BinaryDownloadStatus({
    required this.name,
    required this.percent,
    required this.speed,
  });

  final String name;
  final double percent;
  final String speed;

  String get label => '$name ${percent.toStringAsFixed(0)}% • $speed';
}

class Binaries {
  Binaries._();

  static final ValueNotifier<BinaryDownloadStatus?> downloadStatus =
      ValueNotifier<BinaryDownloadStatus?>(null);

  static String get _platformDir {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'windows';
  }

  static String get _exeExt => Platform.isWindows ? '.exe' : '';

  static String? get projectRoot {
    final candidates = <String>{
      Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
    };
    for (final candidate in candidates) {
      final script = p.join(candidate, 'tool', 'fetch_binaries.sh');
      if (File(script).existsSync()) return candidate;
    }
    final parent = p.dirname(Directory.current.path);
    final fallback = p.join(parent, 'Scrup');
    final script = p.join(fallback, 'tool', 'fetch_binaries.sh');
    if (File(script).existsSync()) return fallback;
    return null;
  }

  static String? _platformUrlYtDlp() {
    const base = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download';
    final win = '$base/yt-dlp.exe';
    if (Platform.isWindows) return win;
    return '$base/yt-dlp';
  }

  static String? _platformUrlFfmpeg() {
    if (Platform.isWindows) {
      return 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
    }
    if (Platform.isLinux) {
      return 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz';
    }
    if (Platform.isMacOS) {
      final version = '7.1';
      return 'https://evermeet.cx/ffmpeg/getrelease/ffmpeg/$version';
    }
    return null;
  }

  /// Devuelve un par (comando, args) listo para Process.start/run.
  /// Si curl está disponible, devuelve el comando directamente (sin shell
  /// wrapper). En Windows usa PowerShell como fallback.
  static (String, List<String>)? _downloadCommand(
    String url,
    String outputPath,
  ) {
    final curl = _which('curl');
    if (curl != null) {
      return (curl, ['-L', '--fail', '--output', outputPath, url]);
    }
    if (Platform.isWindows) {
      final powershell = _which('powershell');
      if (powershell != null) {
        final escaped = outputPath
            .replaceAll('\\', '\\\\')
            .replaceAll('"', '\\"');
        final escapedUrl = url.replaceAll('"', '\\"');
        final script =
            'Invoke-WebRequest -Uri \\"$escapedUrl\\" '
            '-OutFile \\"$escaped\\"';
        return (
          powershell,
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
        );
      }
    }
    return null;
  }

  static void _ensureExecutable(String path) {
    if (Platform.isWindows) return;
    try {
      Process.runSync(
        'chmod',
        ['+x', path],
        environment: Platform.environment,
      );
    } catch (_) {}
  }

  static BinaryDownloadStatus? _parseDownloadStatus(
    String line,
    String name,
  ) {
    final percentMatch = RegExp(r'(\d{1,3})\s*%').firstMatch(line);
    final speedMatch = RegExp(
      r'(\d+(?:\.\d+)?\s*(?:[KMG]i?B|B)/s)',
    ).firstMatch(line);
    if (percentMatch == null && speedMatch == null) return null;
    final double percent = percentMatch != null
        ? (double.tryParse(percentMatch.group(1)!) ?? 0.0)
        : 0.0;
    final String speed =
        speedMatch != null ? speedMatch.group(1)!.trim() : '0 KB/s';
    return BinaryDownloadStatus(name: name, percent: percent, speed: speed);
  }

  static Future<ProcessResult> _runDownloadWithProgress(
    String executable,
    List<String> arguments, {
    required String label,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: Platform.environment,
    );
    final content = StringBuffer();
    final progressLines = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in progressLines) {
      content.writeln(line);
      final status = _parseDownloadStatus(line, label);
      if (status != null) {
        downloadStatus.value = status;
      }
    }

    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = content.toString();
    final exitCode = await process.exitCode;
    return ProcessResult(0, exitCode, stdout, stderr);
  }

  static Future<bool> _downloadYtDlp(String dir) async {
    final target = p.join(dir, 'yt-dlp$_exeExt');
    final url = _platformUrlYtDlp();
    if (url == null) return false;
    final cmd = _downloadCommand(url, target);
    if (cmd == null) return false;

    final (exe, args) = cmd;
    final res = await _runDownloadWithProgress(exe, args, label: 'yt-dlp');
    if (res.exitCode != 0) {
      debugPrint('[Scrup] yt-dlp download failed: ${res.stderr}');
      return false;
    }
    _ensureExecutable(target);
    return File(target).existsSync();
  }

  static Future<bool> _downloadFfmpeg(String dir) async {
    final url = _platformUrlFfmpeg();
    if (url == null) return false;
    final ffmpegDir = p.join(dir, 'ffmpeg');
    await Directory(ffmpegDir).create(recursive: true);

    if (Platform.isWindows) {
      final zip = p.join(dir, 'ffmpeg-release-essentials.zip');
      final cmd = _downloadCommand(url, zip);
      if (cmd == null) return false;
      final (exe, args) = cmd;
      final res = await Process.run(exe, args, environment: Platform.environment);
      if (res.exitCode != 0) {
        debugPrint('[Scrup] ffmpeg download failed: ${res.stderr}');
        return false;
      }
      final unzip = _which('powershell') ?? _which('tar');
      if (unzip == null) return false;
      final extractArgs = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Expand-Archive -LiteralPath '
            '"${zip.replaceAll('/', '\\')}" '
            '-DestinationPath '
            '"${ffmpegDir.replaceAll('/', '\\')}" -Force',
      ];
      final extract = await _runDownloadWithProgress(
        unzip,
        extractArgs,
        label: 'ffmpeg',
      );
      if (extract.exitCode != 0) {
        debugPrint('[Scrup] ffmpeg unzip failed: ${extract.stderr}');
        return false;
      }
      // Limpiar el zip después de extraer
      try {
        final zipFile = File(zip);
        if (zipFile.existsSync()) await zipFile.delete();
      } catch (_) {}
      // Verificar que ffmpeg.exe existe (directo o anidado)
      return _findFfmpegInDir(ffmpegDir) != null;
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final tarPath = p.join(dir, 'ffmpeg-static.tar');
      final cmd = _downloadCommand(url, tarPath);
      if (cmd == null) return false;
      final (exe, args) = cmd;
      final res = await Process.run(exe, args, environment: Platform.environment);
      if (res.exitCode != 0) {
        debugPrint('[Scrup] ffmpeg download failed: ${res.stderr}');
        return false;
      }
      final tar = _which('tar');
      if (tar == null) return false;
      final extract = await _runDownloadWithProgress(
        tar,
        [
          '-xJf',
          tarPath,
          '-C',
          ffmpegDir,
          '--strip-components=1',
          '--wildcards',
          '*/ffmpeg',
          '*/ffprobe',
        ],
        label: 'ffmpeg',
      );
      if (extract.exitCode != 0) {
        debugPrint('[Scrup] ffmpeg tar extract failed: ${extract.stderr}');
        return false;
      }
      try {
        final tarFile = File(tarPath);
        if (tarFile.existsSync()) await tarFile.delete();
      } catch (_) {}
      final ffmpeg = p.join(ffmpegDir, 'ffmpeg');
      final ffprobe = p.join(ffmpegDir, 'ffprobe');
      if (File(ffmpeg).existsSync() && File(ffprobe).existsSync()) return true;
      return false;
    }

    return false;
  }

  /// Busca recursivamente `ffmpeg.exe` (o `ffmpeg` en Unix) dentro de
  /// [dir], incluyendo subcarpetas anidadas (el zip de gyan.dev crea
  /// `ffmpeg-X.Y.Z-essentials_build/bin/ffmpeg.exe`).
  static String? _findFfmpegInDir(String dir) {
    try {
      final ffmpegDir = Directory(dir);
      if (!ffmpegDir.existsSync()) return null;
      for (final entry in ffmpegDir.listSync(recursive: true)) {
        if (entry is File && p.basename(entry.path) == 'ffmpeg$_exeExt') {
          return entry.path;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Busca ffmpeg.exe en múltiples ubicaciones: junto a searchDir, en
  /// subcarpetas anidadas del zip, y en la ubicación legacy junto al .exe.
  static String? _findFfmpeg() {
    final dir = _searchDir();
    final exeDir = p.dirname(Platform.resolvedExecutable);

    // 1. <searchDir>/ffmpeg/ffmpeg.exe
    if (dir != null) {
      final candidate = p.join(dir, 'ffmpeg', 'ffmpeg$_exeExt');
      if (File(candidate).existsSync()) return candidate;
      // 2. <searchDir>/ffmpeg.exe (sin subcarpeta)
      final flat = p.join(dir, 'ffmpeg$_exeExt');
      if (File(flat).existsSync()) return flat;
      // 3. <searchDir>/ffmpeg/**/ffmpeg.exe (zip anidado)
      final nested = _findFfmpegInDir(p.join(dir, 'ffmpeg'));
      if (nested != null) return nested;
    }

    // 4-6. Fallback legacy: junto al .exe (sin carpeta tools)
    if (dir != exeDir) {
      final legacyCandidate = p.join(exeDir, 'ffmpeg', 'ffmpeg$_exeExt');
      if (File(legacyCandidate).existsSync()) return legacyCandidate;
      final legacyFlat = p.join(exeDir, 'ffmpeg$_exeExt');
      if (File(legacyFlat).existsSync()) return legacyFlat;
      final legacyNested = _findFfmpegInDir(p.join(exeDir, 'ffmpeg'));
      if (legacyNested != null) return legacyNested;
    }

    return null;
  }

  static Future<bool> ensureSidecarsPresent() async {
    if (_ytdlpPath != null && _ffmpegPath != null) return true;

    // Verificación rápida: buscar en todas las ubicaciones conocidas
    // antes de decidir descargar. Esto evita la notificación cuando los
    // binarios ya existen.
    ytdlpPath;
    ffmpegPath;
    if (_ytdlpPath != null && _ffmpegPath != null) return true;

    // Determinar el directorio de descarga:
    // - En builds release/paquetados: <exeDir>/tools/
    // - En desarrollo: projectRoot/bin/<plataforma>
    String downloadDir;
    final root = projectRoot;
    if (root != null) {
      downloadDir = p.join(root, 'bin', _platformDir);
    } else {
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        downloadDir = p.join(exeDir, 'tools');
      } catch (_) {
        downloadDir = Directory.current.path;
      }
    }
    await Directory(downloadDir).create(recursive: true);

    final downloadedYtDlp = await _downloadYtDlp(downloadDir);
    final downloadedFfmpeg = await _downloadFfmpeg(downloadDir);
    if (!downloadedYtDlp && !downloadedFfmpeg) {
      debugPrint(
        '[Scrup] Auto-fetch sidecars skipped: '
        'no native download path available.',
      );
      return false;
    }

    // Re-buscar los binarios después de descargarlos.
    _ytdlpPath = null;
    _ffmpegPath = null;
    _denoPath = null;
    ytdlpPath;
    ffmpegPath;
    return true;
  }

  /// Directorio donde buscaremos los binarios, si existe.
  static String? _searchDir() {
    final env = Platform.environment;
    if (env['SCRUP_YTDLP_PATH'] != null &&
        env['SCRUP_YTDLP_PATH']!.isNotEmpty) {
      return p.dirname(env['SCRUP_YTDLP_PATH']!);
    }
    // Modo empaquetado: buscar en <exeDir>/tools/ (nuevo) y
    // <exeDir>/ (legacy, binarios descargados antes del cambio).
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final toolsDir = p.join(exeDir, 'tools');
      if (File(p.join(toolsDir, 'yt-dlp$_exeExt')).existsSync()) {
        return toolsDir;
      }
      // Fallback legacy: binarios junto al .exe (sin carpeta tools).
      if (File(p.join(exeDir, 'yt-dlp$_exeExt')).existsSync()) {
        return exeDir;
      }
    } catch (_) {}
    // Desarrollo desde projectRoot (más confiable que CWD).
    final root = projectRoot;
    if (root != null) {
      final dev = p.join(root, 'bin', _platformDir);
      if (File(p.join(dev, 'yt-dlp$_exeExt')).existsSync()) {
        return dev;
      }
    }
    // Desarrollo: relativo al CWD del proyecto (fallback).
    final cwdDev = p.join(Directory.current.path, 'bin', _platformDir);
    if (File(p.join(cwdDev, 'yt-dlp$_exeExt')).existsSync()) {
      return cwdDev;
    }
    return null;
  }

  static String? _ytdlpPath;
  static String? _ffmpegPath;
  static String? _denoPath;

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
    // Buscar en múltiples ubicaciones (directo, flat, anidado, legacy).
    final found = _findFfmpeg();
    if (found != null) {
      _ffmpegPath = found;
      return _ffmpegPath;
    }
    final inPath = _which('ffmpeg');
    if (inPath != null) {
      _ffmpegPath = inPath;
      return _ffmpegPath;
    }
    return null;
  }

  /// Runtime JS de yt-dlp (deno) junto a los binarios, o `null` si no hay.
  ///
  /// yt-dlp 2026+ ha **deprecado la extracción sin runtime JS** de YouTube
  /// ("some formats may be missing"). Si deno está en el PATH de los
  /// subprocesos, yt-dlp lo detecta solo y la extracción queda completa y a
  /// prueba del cierre del camino sin JS. Se busca en el directorio de
  /// binarios (descargado por `tool/fetch_binaries.sh`), en `SCRUP_DENO_PATH`
  /// y en el PATH del sistema (por si el usuario lo tiene instalado).
  static String? get denoPath {
    if (_denoPath != null) return _denoPath;
    final env = Platform.environment['SCRUP_DENO_PATH'];
    if (env != null && env.isNotEmpty) {
      _denoPath = env;
      return _denoPath;
    }
    final dir = _searchDir();
    if (dir != null) {
      final candidate = p.join(dir, 'deno$_exeExt');
      if (File(candidate).existsSync()) {
        _denoPath = candidate;
        return _denoPath;
      }
    }
    final inPath = _which('deno');
    if (inPath != null) {
      _denoPath = inPath;
      return _denoPath;
    }
    return null;
  }

  /// Directorios que deben añadirse al PATH de los subprocesos (yt-dlp busca
  /// ahí ffmpeg y el runtime JS): el directorio de binarios (donde vive deno)
  /// y el directorio de ffmpeg. Sin duplicados y en orden estable.
  static List<String> get pathDirs {
    final dirs = <String>[];
    final binDir = _searchDir();
    if (binDir != null) dirs.add(binDir);
    final ffmpeg = ffmpegPath;
    if (ffmpeg != null) {
      final ffDir = p.dirname(ffmpeg);
      if (!dirs.contains(ffDir)) dirs.add(ffDir);
    }
    return dirs;
  }

  static String? _which(String name) {
    if (Platform.isWindows) {
      final cmd = Process.runSync('where', [name]);
      if (cmd.exitCode == 0) {
        final lines = (cmd.stdout as String)
            .trim()
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
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
