import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  /// Mobile targets (Android/iOS) have no desktop sidecar toolchain; the
  /// UI must not try to download/run OS binaries there.
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
  static bool get isDesktop => !isMobile;

  static String get _platformDir {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'windows';
  }

  static String get _exeExt => Platform.isWindows ? '.exe' : '';

  // ── Toolchain Android (CPython + yt-dlp) ────────────────────────────────
  // Generada por tool/fetch_android_toolchain.sh y empaquetada como ASSETS
  // NATIVOS (android/app/src/main/assets/toolchain/) — no pubspec — porque
  // Flutter no permite assets por plataforma. Se materializa una sola vez a
  // la carpeta de archivos de la app y ahí se ejecuta `python3 <root>/yt-dlp`.
  static const String _androidToolchainAbi = 'aarch64';
  static const String _androidToolchainChannel = 'com.scrup.music.toolchain';

  static String? _androidToolchainRoot;
  static Future<bool>? _androidToolchainFuture;

  /// En Android el binario a ejecutar es `<root>/python3` y yt-dlp se pasa
  /// como primer argumento (zipapp); en el resto de plataformas es nulo y los
  /// procesos deben invocar directamente [`ytdlpPath`].
  static String? get ytDlpScript {
    if (!Platform.isAndroid) return null;
    final root = _androidToolchainRoot;
    if (root == null) return null;
    return p.join(root, 'yt-dlp');
  }

  /// Inicia (una sola vez) la extracción de la toolchain CPython/yt-dlp desde
  /// los assets nativos. No bloquea el arranque: los primeros usos fallarán
  /// con "yt-dlp no encontrado" hasta que termine (unos segundos).
  static Future<bool> ensureAndroidToolchain() {
    if (!Platform.isAndroid) return Future.value(false);
    return _androidToolchainFuture ??= _extractAndroidToolchain();
  }

  static Future<bool> _extractAndroidToolchain() async {
    final channel = const MethodChannel(_androidToolchainChannel);
    try {
      final filesDir = await getApplicationSupportDirectory();
      final root = p.join(filesDir.path, 'toolchain', _androidToolchainAbi);
      final marker = p.join(filesDir.path, '.scrup_toolchain_v2');
      if (File(marker).existsSync()) {
        debugPrint('[Scrup] toolchain marker existe, ejecutando chcon en ejecutables');
        _androidToolchainRoot = root;
        for (final name in const ['python3', 'yt-dlp']) {
          _ensureExecutable(p.join(root, name));
        }
        return true;
      }

      // Leer el inventario (asset nativo).
      final manifestPath = '$_androidToolchainAbi/manifest.json';
      final manifestBytes = await _readMany(channel, [manifestPath]);
      final mb = manifestBytes[manifestPath];
      if (mb == null) return _failToolchain('manifest no leído');
      final map = jsonDecode(utf8.decode(mb)) as Map<String, dynamic>;
      final files = (map['files'] as List<dynamic>? ?? []).cast<String>();
      if (files.isEmpty) return _failToolchain('manifest sin archivos');

      // Copiar por LOTES (≤ 12 archivos por invocación) para no superar el
      // límite de ~1MB del Binder por transacción de MethodChannel.
      // Los assets que no existan en el APK (directorios de stdlib que
      // aapt2 rechaza por comenzar con '_') se avisan pero no abortan:
      // yt-dlp funciona perfectamente sin ellos.
      const batchSize = 12;
      const essentialBaseNames = {'python3', 'yt-dlp'};
      var missingEssential = <String>[];
      var written = 0;
      var skipped = 0;
      for (var i = 0; i < files.length; i += batchSize) {
        final batch = files.sublist(
          i,
          i + batchSize > files.length ? files.length : i + batchSize,
        );
        final keys = [for (final rel in batch) '$_androidToolchainAbi/$rel'];
        final data = await _readMany(channel, keys);
        for (final rel in batch) {
          final bytes = data['$_androidToolchainAbi/$rel'];
          if (bytes == null) {
            skipped++;
            // Solo registrar como error si es un archivo esencial.
            final bn = p.basename(rel);
            if (essentialBaseNames.contains(bn)) {
              missingEssential.add(rel);
            }
            continue;
          }
          final target = File(p.join(root, rel));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes);
          written++;
        }
      }
      if (missingEssential.isNotEmpty) {
        debugPrint(
            '[Scrup] toolchain: ${missingEssential.length} asset(s) esencial(es'
            ' perdido(s): ${missingEssential.join(", ")}');
      }

      const execNames = {'python3', 'yt-dlp'};
      for (final rel in files) {
        if (execNames.contains(p.basename(rel))) {
          _ensureExecutable(p.join(root, rel));
        }
      }

      // PYTHONHOME/TMPDIR esperan esta carpeta.
      await Directory(p.join(root, 'tmp')).create();
      await File(marker).writeAsString('ok');

      final python3Ok = File(p.join(root, 'python3')).existsSync();
      final ytdlpOk = File(p.join(root, 'yt-dlp')).existsSync();
      if (!python3Ok || !ytdlpOk) {
        return _failToolchain(
            'falta python3/yt-dlp tras copiar (python3=$python3Ok, yt-dlp=$ytdlpOk)');
      }
      _androidToolchainRoot = root;
      final skippedNote =
          skipped > 0 ? ' — $skipped recursos stdlib no empaquetados por aapt2' : '';
      debugPrint(
          '[Scrup] toolchain android lista en $root '
          '($written archivos copiados, $skipped omitidos$skippedNote)');
      return true;
    } catch (e, st) {
      debugPrint('[Scrup] toolchain android falló: $e');
      assert(() {
        debugPrint(st.toString());
        return true;
      }());
      return false;
    }
  }

  static bool _failToolchain(String why) {
    debugPrint('[Scrup] toolchain android incompleta: $why');
    return false;
  }

  /// Lee un lote de assets nativos (camino `toolchain/<abi>/<rel>`). Devuelve
  /// un mapa rel→bytes; los archivos que no puedan leerse se omiten.
  static Future<Map<String, Uint8List>> _readMany(
    MethodChannel channel,
    List<String> keys,
  ) async {
    final raw = await channel.invokeMethod<Map<Object?, Object?>>(
      'readMany',
      {'paths': keys},
    );
    if (raw == null) return const {};
    final out = <String, Uint8List>{};
    raw.forEach((k, v) {
      if (k is String && v is Uint8List) out[k] = v;
    });
    return out;
  }

  /// Variables de entorno necesarias para ejecutar el python3 de Android
  /// (loader de bionic: LD_LIBRARY_PATH para encontrar libpython/openssl).
  static Map<String, String> androidToolchainEnv() {
    if (!Platform.isAndroid) return const {};
    final root = _androidToolchainRoot;
    if (root == null) return const {};
    return {
      'LD_LIBRARY_PATH': p.join(root, 'lib'),
      'PYTHONHOME': root,
      'PYTHONUTF8': '1',
      'PYTHONNOUSERSITE': '1',
      'TMPDIR': p.join(root, 'tmp'),
    };
  }

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

  // Returns (executable, args) for downloading a URL.
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
      final r = Process.runSync('chmod', ['+x', path], environment: Platform.environment);
      if (r.exitCode != 0) debugPrint('[Scrup] chmod $path falló: ${r.stderr}');
    } catch (e) {
      debugPrint('[Scrup] chmod $path error: $e');
    }
    try {
      final r = Process.runSync('chcon', ['u:object_r:shell_data_file:s0', path], environment: Platform.environment);
      if (r.exitCode != 0) debugPrint('[Scrup] chcon $path falló: ${r.stderr}');
    } catch (e) {
      debugPrint('[Scrup] chcon $path error: $e');
    }
  }

  static BinaryDownloadStatus? _parseDownloadStatus(String line, String name) {
    final percentMatch = RegExp(r'(\d{1,3})\s*%').firstMatch(line);
    final speedMatch = RegExp(
      r'(\d+(?:\.\d+)?\s*(?:[KMG]i?B|B)/s)',
    ).firstMatch(line);
    if (percentMatch == null && speedMatch == null) return null;
    final double percent = percentMatch != null
        ? (double.tryParse(percentMatch.group(1)!) ?? 0.0)
        : 0.0;
    final String speed = speedMatch != null
        ? speedMatch.group(1)!.trim()
        : '0 KB/s';
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
      final res = await Process.run(
        exe,
        args,
        environment: Platform.environment,
      );
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
      final res = await Process.run(
        exe,
        args,
        environment: Platform.environment,
      );
      if (res.exitCode != 0) {
        debugPrint('[Scrup] ffmpeg download failed: ${res.stderr}');
        return false;
      }
      final tar = _which('tar');
      if (tar == null) return false;
      final extract = await _runDownloadWithProgress(tar, [
        '-xJf',
        tarPath,
        '-C',
        ffmpegDir,
        '--strip-components=1',
        '--wildcards',
        '*/ffmpeg',
        '*/ffprobe',
      ], label: 'ffmpeg');
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

  // Recursively finds ffmpeg in dir (handles nested zip extraction).
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

  // Searches for ffmpeg in multiple known locations.
  static String? _findFfmpeg() {
    final dir = _searchDir();
    final exeDir = p.dirname(Platform.resolvedExecutable);

    // Search tools dir first, then legacy location next to exe.
    if (dir != null) {
      final candidate = p.join(dir, 'ffmpeg', 'ffmpeg$_exeExt');
      if (File(candidate).existsSync()) return candidate;
      final flat = p.join(dir, 'ffmpeg$_exeExt');
      if (File(flat).existsSync()) return flat;
      final nested = _findFfmpegInDir(p.join(dir, 'ffmpeg'));
      if (nested != null) return nested;
    }

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

    // Quick check: search known locations before downloading.
    ytdlpPath;
    ffmpegPath;
    if (_ytdlpPath != null && _ffmpegPath != null) return true;

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

    // Re-resolve paths after download.
    _ytdlpPath = null;
    _ffmpegPath = null;
    _denoPath = null;
    ytdlpPath;
    ffmpegPath;
    return true;
  }

  static String? _searchDir() {
    final env = Platform.environment;
    if (env['SCRUP_YTDLP_PATH'] != null &&
        env['SCRUP_YTDLP_PATH']!.isNotEmpty) {
      return p.dirname(env['SCRUP_YTDLP_PATH']!);
    }
    // Packaged: <exeDir>/tools/ first, then legacy <exeDir>/.
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final toolsDir = p.join(exeDir, 'tools');
      if (File(p.join(toolsDir, 'yt-dlp$_exeExt')).existsSync()) {
        return toolsDir;
      }
      if (File(p.join(exeDir, 'yt-dlp$_exeExt')).existsSync()) {
        return exeDir;
      }
    } catch (_) {}
    // Development: projectRoot/bin/<platform>, then CWD fallback.
    final root = projectRoot;
    if (root != null) {
      final dev = p.join(root, 'bin', _platformDir);
      if (File(p.join(dev, 'yt-dlp$_exeExt')).existsSync()) {
        return dev;
      }
    }
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
    // En Android yt-dlp se ejecuta con el python3 de la toolchain extraída;
    // el script se pasa aparte (ver ytDlpScript).
    if (Platform.isAndroid) {
      final root = _androidToolchainRoot;
      if (root == null) return null;
      final exe = p.join(root, 'python3');
      if (!File(exe).existsSync()) return null;
      _ytdlpPath = exe;
      return _ytdlpPath;
    }
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

  /// Resuelve el binario yt-dlp esperando, en Android, a que la toolchain
  /// termine de extraerse de los assets. Así las primeras búsquedas no fallan
  /// con "yt-dlp no encontrado" durante la ventana de extracción (~segundos).
  /// Compatible con el patrón sincrónico del resto: devuelve el camino o null.
  static Future<String?> resolveYtDlp() async {
    if (Platform.isAndroid) {
      await ensureAndroidToolchain();
    }
    return ytdlpPath;
  }

  static String? get ffmpegPath {
    if (_ffmpegPath != null) return _ffmpegPath;
    final env = Platform.environment['SCRUP_FFMPEG_PATH'];
    if (env != null && env.isNotEmpty) {
      _ffmpegPath = env;
      return _ffmpegPath;
    }
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

  // Deno runtime for yt-dlp's JS-based extraction.
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

  // Dirs to add to subprocess PATH (for ffmpeg and deno).
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
