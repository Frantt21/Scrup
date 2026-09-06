import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/track.dart';

/// Entrada cacheada: resultados + timestamp para el TTL.
class _CacheEntry {
  final List<Track> tracks;
  final DateTime at;

  const _CacheEntry(this.tracks, this.at);

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'tracks': [for (final t in tracks) _trackToJson(t)],
  };

  static _CacheEntry? fromJson(Map<String, dynamic> json) {
    final atMs = json['at'];
    final raw = json['tracks'];
    if (atMs is! int || raw is! List) return null;
    final tracks = <Track>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      try {
        final t = _trackFromJson(e);
        if (t != null && t.id.isNotEmpty) tracks.add(t);
      } catch (_) {}
    }
    if (tracks.isEmpty) return null;
    return _CacheEntry(tracks, DateTime.fromMillisecondsSinceEpoch(atMs));
  }
}

/// (De)serialización mínima de Track para el caché en disco. `cleanMetadata`
/// es proveniencia en memoria y no se serializa: al recargar de disco se
/// marca limpia cuando NO hay `album` (sin matching Deezer previo).
Map<String, dynamic> _trackToJson(Track t) => {
  'id': t.id,
  'title': t.title,
  'artist': t.artist,
  'dur': t.duration?.inMilliseconds,
  'thumb': t.thumbnailUrl,
  'album': t.album,
  'chan': t.artistChannelId,
  'subs': t.subscriberCount,
  'plays': t.playCountText,
};

Track? _trackFromJson(Map<String, dynamic> j) {
  final id = j['id'];
  final title = j['title'];
  final artist = j['artist'];
  if (id is! String || title is! String || artist is! String) return null;
  final durMs = j['dur'];
  final thumb = j['thumb'];
  final album = j['album'];
  final chan = j['chan'];
  final subs = j['subs'];
  return Track(
    id: id,
    title: title,
    artist: artist,
    duration: durMs is int && durMs > 0 ? Duration(milliseconds: durMs) : null,
    thumbnailUrl: thumb is String ? thumb : null,
    album: album is String ? album : null,
    // Sin `album` no hubo matching Deezer: metadatos limpios de origen.
    cleanMetadata: album == null,
    artistChannelId: chan is String && chan.isNotEmpty ? chan : null,
    subscriberCount: subs is int && subs > 0 ? subs : null,
    playCountText: j['plays'] is String ? j['plays'] as String : null,
  );
}

/// Caché PERSISTENTE de búsquedas (memoria + disco):
/// - La primera vez que un dispositivo hace una búsqueda paga el coste
///   completo (yt-dlp ~6-8s). Las siguientes sesiones la sirven de disco
///   en <5ms mientras no expire el TTL./// - LRU simple por inserción ordenada, con tope de entradas y limpieza
/// de vencidas en cada carga/guardado.
///
/// `version` invalida TODO el caché cuando cambia el formato serializado
/// (p. ej. al añadir `chan`/`subs` de canal a las entradas: las antiguas no
/// pueden derivar artistas, así que se descartan y se vuelven a buscar).
class SearchCacheStore {
  static const int version = 2;

  SearchCacheStore({
    this.ttl = const Duration(hours: 6),
    this.maxEntries = 60,
    this.directoryOverride,
  });

  final Duration ttl;
  final int maxEntries;
  final Directory? directoryOverride;

  final Map<String, _CacheEntry> _mem = {};
  Directory? _dir;
  Timer? _saveTimer;
  bool _dirty = false;

  String _key(String source, String query, int limit) =>
      '$source|$query|$limit';

  Future<Directory> _cacheDir() async {
    final override = directoryOverride;
    if (override != null) return override;
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'search_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _file(Directory dir) => File(p.join(dir.path, 'searches.json'));

  File _versionFile(Directory dir) =>
      File(p.join(dir.path, 'version.json'));

  /// Resultados cacheados y vigentes, o null.
  Future<List<Track>?> get(String query, int limit) async {
    return getForSource('music', query, limit);
  }

  Future<List<Track>?> getForSource(
    String source,
    String query,
    int limit,
  ) async {
    final key = _key(source, query.trim().toLowerCase(), limit);
    final hit = _mem[key];
    if (hit != null) {
      if (DateTime.now().difference(hit.at) < ttl) return hit.tracks;
      _mem.remove(key);
      return null;
    }
    // Cache-miss en memoria: intenta cargar de disco UNA vez por key.
    await _loadFromDisk(key);
    final diskHit = _mem[key];
    if (diskHit == null) return null;
    if (DateTime.now().difference(diskHit.at) < ttl) return diskHit.tracks;
    _mem.remove(key);
    return null;
  }

  /// Guarda resultados (memoria + persistencia diferida).
  Future<void> put(
    String query,
    int limit,
    List<Track> tracks, {
    String source = 'music',
  }) async {
    if (tracks.isEmpty) return; // fallos no se cachean
    final key = _key(source, query.trim().toLowerCase(), limit);
    // Reinserta al final = LRU por orden.
    _mem.remove(key);
    while (_mem.length >= maxEntries) {
      _mem.remove(_mem.keys.first);
    }
    _mem[key] = _CacheEntry(tracks, DateTime.now());
    _dirty = true;
    // Persistencia diferida 2s: agrupa ráfagas (escribir search mientras
    // se escribe otra cosa no bloquea; el JSON de 60 búsquedas es pequeño).
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_flush());
    });
  }

  Future<void> _loadFromDisk(String key) async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final dir = await _cacheDir();
      // Versión del formato: si difiere, borra el archivo y empieza de
      // cero (las entradas viejas sin canal no sirven para derivar).
      final vf = _versionFile(dir);
      var stale = true;
      if (await vf.exists()) {
        try {
          final v = jsonDecode(await vf.readAsString());
          if (v is Map && v['format'] == version) stale = false;
        } catch (_) {}
      }
      final f = _file(dir);
      if (stale) {
        _dirty = false;
        try {
          if (await f.exists()) await f.delete();
          if (await vf.exists()) await vf.delete();
        } catch (_) {}
        unawaited(
          vf.writeAsString(jsonEncode({'format': version}), flush: true),
        );
        return;
      }
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;
      final now = DateTime.now();
      for (final entry in data.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        final parsed = _CacheEntry.fromJson(entry.value);
        if (parsed == null) continue;
        if (now.difference(parsed.at) >= ttl) continue; // vencida: descarta
        _mem[entry.key] = parsed;
      }
      // La key pedida puede haber vencido entera en disco.
      _mem.removeWhere((_, v) => now.difference(v.at) >= ttl);
    } catch (_) {
      // Caché corrupta o ilegible: se regenera sola.
    }
  }

  bool _diskLoaded = false;

  Future<void> _flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final dir = await _cacheDir();
      final now = DateTime.now();
      _mem.removeWhere((_, v) => now.difference(v.at) >= ttl);
      final data = {for (final e in _mem.entries) e.key: e.value.toJson()};
      await _file(dir).writeAsString(jsonEncode(data), flush: true);
      // Marca el formato actual para que la próxima sesión no lo invalide.
      final vf = _versionFile(dir);
      if (!await vf.exists()) {
        unawaited(
          vf.writeAsString(jsonEncode({'format': version}), flush: true),
        );
      }
    } catch (_) {}
  }

  /// Vacía el caché (p. ej. acción de "limpiar caché" en ajustes).
  Future<void> clear() async {
    _mem.clear();
    _dirty = false;
    _saveTimer?.cancel();
    try {
      final dir = await _cacheDir();
      final f = _file(dir);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
