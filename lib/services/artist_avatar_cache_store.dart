import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Caché PERSISTENTE de avatares de canal (browseId `UC…` → URL hi-res).
///
/// - Un solo JSON (`avatars.json`) con el mapa completo; se carga UNA vez
///   por sesión y las escrituras van diferidas (debounce 1s).
/// - Los valores NO expiran por TTL: la REVALIDACIÓN en background (una
///   request por artista en cada búsqueda, orquestada por SearchService)
///   es lo que actualiza la URL si el canal cambió su avatar. El disco
///   sirve el avatar INSTANTÁNEO desde el primer arranque.
class ArtistAvatarCacheStore {
  ArtistAvatarCacheStore({this.directoryOverride});

  final Directory? directoryOverride;

  final Map<String, String> _mem = {};
  bool _loaded = false;
  Timer? _flushTimer;
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final override = directoryOverride;
    if (override != null) return override;
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'artist_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Carga el mapa desde disco (UNA vez por sesión). Los fallos de lectura
  /// nunca rompen la app: el mapa queda vacío y se repuebla en background.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, 'avatars.json'));
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map<String, dynamic>) return;
      for (final e in data.entries) {
        final v = e.value;
        if (e.key.isNotEmpty && v is String && v.isNotEmpty) {
          _mem[e.key] = v;
        }
      }
    } catch (_) {}
  }

  /// URL cacheada del avatar (disco → memoria la primera vez), o null.
  Future<String?> get(String browseId) async {
    await _ensureLoaded();
    return _mem[browseId];
  }

  /// Guarda/actualiza un avatar (memoria + disco diferido 1s).
  Future<void> put(String browseId, String url) async {
    await _ensureLoaded();
    if (_mem[browseId] == url) return;
    _mem[browseId] = url;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, 'avatars.json'));
      await f.writeAsString(jsonEncode(_mem), flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _mem.clear();
    _flushTimer?.cancel();
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, 'avatars.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
