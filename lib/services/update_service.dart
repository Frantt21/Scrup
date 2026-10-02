import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/version.g.dart';

/// Un asset adjunto a un release de GitHub.
class UpdateAsset {
  final String name;
  final String url;
  final int size;

  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
  });
}

/// Resultado de comprobar actualizaciones: hay una versión más nueva que la
/// instalada. `asset` es el archivo para ESTA plataforma (null en Linux, donde
/// abrimos la página del release en vez de descargar).
class UpdateInfo {
  final String version; // "1.0.1" (sin la "v" del tag)
  final String tag; // "v1.0.1"
  final String title; // nombre del release
  final String notes; // cuerpo markdown del release
  final String releaseUrl; // página HTML del release
  final UpdateAsset? asset;

  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.title,
    required this.notes,
    required this.releaseUrl,
    required this.asset,
  });
}

/// Comprueba los releases/tags del repo de GitHub y, si hay una versión más
/// nueva, resuelve el asset de la plataforma actual. También descarga el asset
/// y lo lanza (instalador en Windows, APK en Android). En Linux no descarga:
/// la UI abre la página del release (el sandbox de flatpak no puede ejecutar
/// `flatpak install`).
class UpdateService {
  static const String _repo = 'Frantt21/Scrup';
  static const String _apiLatest =
      'https://api.github.com/repos/$_repo/releases/latest';

  /// Canal nativo de Android para lanzar el instalador del APK.
  static const MethodChannel _installChannel = MethodChannel(
    'com.scrup.scrup/install',
  );

  static String get _userAgent => 'Scrup/$kAppVersionFull';

  /// Consulta el último release. Devuelve `null` si no hay actualización, si
  /// falla la red o si el release es draft/prerelease. Nunca lanza.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final res = await http
          .get(
            Uri.parse(_apiLatest),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(res.body);
      if (map is! Map) return null;
      if (map['draft'] == true || map['prerelease'] == true) return null;

      final tag = (map['tag_name'] as String? ?? '').trim();
      final version = _normalizeVersion(tag);
      if (version.isEmpty) return null;
      if (!_isNewer(version, kAppVersion)) return null;

      final rawAssets = map['assets'];
      final assets = rawAssets is List ? rawAssets : const [];
      final asset = _pickAsset(assets);

      return UpdateInfo(
        version: version,
        tag: tag,
        title: (map['name'] as String? ?? '').trim().isEmpty
            ? tag
            : (map['name'] as String).trim(),
        notes: (map['body'] as String? ?? '').trim(),
        releaseUrl: (map['html_url'] as String? ?? '').trim().isEmpty
            ? 'https://github.com/$_repo/releases'
            : (map['html_url'] as String).trim(),
        asset: asset,
      );
    } catch (_) {
      // Red caída / JSON inválido / timeout: no hay aviso, silencioso.
      return null;
    }
  }

  /// Descarga el asset del release a la carpeta temporal de la app, con
  /// progreso. Devuelve el archivo descargado. Lanza en caso de error.
  Future<File> downloadAsset(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final asset = info.asset;
    if (asset == null) {
      throw StateError('No hay asset para esta plataforma');
    }
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, asset.name));
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(asset.url));
      req.headers['User-Agent'] = _userAgent;
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(asset.url));
      }
      final total = res.contentLength ?? asset.size;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// Lanza el archivo descargado según la plataforma:
  /// - Android: intent de instalación de paquete (canal nativo).
  /// - Windows: ejecuta el instalador en modo detached.
  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      await _installChannel.invokeMethod<void>('installApk', {
        'path': file.path,
      });
      return;
    }
    if (Platform.isWindows) {
      await Process.start(
        file.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    // macOS/Linux: no self-install; se abre la página del release desde la UI.
  }

  /// Abre una URL en el navegador/app externa por defecto.
  Future<bool> openUrl(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────

  /// "v1.0.0" → "1.0.0"; conserva el sufijo de build si lo hubiera.
  static String _normalizeVersion(String tag) {
    var v = tag.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    return v.trim();
  }

  /// Compara dos versiones semver (major.minor.patch); ignora el sufijo
  /// `+build` y cualquier pre-release. `true` si [remote] > [local].
  static bool _isNewer(String remote, String local) {
    final r = _parse(remote);
    final l = _parse(local);
    for (var i = 0; i < 3; i++) {
      if (r[i] != l[i]) return r[i] > l[i];
    }
    return false;
  }

  static List<int> _parse(String version) {
    final core = version.split('+').first.split('-').first;
    final parts = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i].trim()) ?? 0) : 0,
    ];
  }

  /// Elige el asset de la plataforma actual.
  /// - Android: `*.apk` (prefiere "universal", luego el mayor tamaño).
  /// - Windows: `*.exe` (prefiere un "Setup").
  /// - macOS: `*.dmg`.
  /// - Linux: null (se abre la página del release).
  static UpdateAsset? _pickAsset(List<dynamic> assets) {
    final parsed = <UpdateAsset>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] as String? ?? '').trim();
      final url = (a['browser_download_url'] as String? ?? '').trim();
      if (name.isEmpty || url.isEmpty) continue;
      parsed.add(
        UpdateAsset(
          name: name,
          url: url,
          size: (a['size'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    if (parsed.isEmpty) return null;

    List<UpdateAsset> withExt(String ext) => [
      for (final a in parsed)
        if (a.name.toLowerCase().endsWith(ext)) a,
    ];

    if (Platform.isAndroid) {
      final apks = withExt('.apk');
      if (apks.isEmpty) return null;
      final universal = apks.where(
        (a) => a.name.toLowerCase().contains('universal'),
      );
      final pool = universal.isNotEmpty ? universal.toList() : apks;
      pool.sort((a, b) => b.size.compareTo(a.size));
      return pool.first;
    }
    if (Platform.isWindows) {
      final exes = withExt('.exe');
      if (exes.isEmpty) return null;
      final setups = exes.where(
        (a) => a.name.toLowerCase().contains('setup'),
      );
      return setups.isNotEmpty ? setups.first : exes.first;
    }
    if (Platform.isMacOS) {
      final dmgs = withExt('.dmg');
      return dmgs.isEmpty ? null : dmgs.first;
    }
    return null;
  }
}
