import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytmusic_service.dart';

/// Caché PERSISTENTE de detalles de artista: un JSON por `browseId` dentro
/// de `artist_cache/`. TTL 24h (el catálogo de un artista casi no cambia en
/// un día) y lectura desde disco en cada `read` (un archivo chico por
/// artista; entrar al screen es gratis y no infla memoria).
class ArtistCacheStore {
  /// Versión del formato: v5 = los álbumes llevan su tipo de lanzamiento
  /// (álbum vs single). Entradas viejas se descartan al leerse.
  /// v4 = invalida los detalles escritos por builds
  /// intermedios (parseo roto de la audiencia mensual: todas las screens
  /// mostraban el MISMO valor). Entradas viejas se descartan al leerse.
  /// v3 = canciones del shelf "Top songs" de la home (con reproducciones y
  /// portada limpia de álbum) + audiencia mensual.
  static const int version = 5;

  ArtistCacheStore({
    this.ttl = const Duration(hours: 24),
    this.directoryOverride,
  });

  final Duration ttl;
  final Directory? directoryOverride;

  final Map<String, YtmArtistDetail> _mem = {};
  final Set<String> _failed = <String>{};
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

  /// Detalle cacheado y vigente, o null.
  Future<YtmArtistDetail?> read(String browseId) async {
    final hit = _mem[browseId];
    if (hit != null) return hit;
    if (_failed.contains(browseId)) return null; // fallo reciente: no reintentar
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, '$browseId.json'));
      if (!await f.exists()) return null;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map<String, dynamic>) return null;
      // Formato viejo o incompatible: descártalo (se reescribe al refetch).
      if (data['v'] != version) return null;
      final atMs = data['at'];
      if (atMs is! int ||
          DateTime.now().difference(
                DateTime.fromMillisecondsSinceEpoch(atMs),
              ) >=
              ttl) {
        return null; // vencido (se sobreescribe al refrescar)
      }
      final detail = detailFromJson(data);
      if (detail == null) return null;
      _mem[browseId] = detail;
      return detail;
    } catch (_) {
      return null;
    }
  }

  /// Guarda (memoria + disco). El disco se escribe en diferido para no
  /// bloquear el frame del primer render del screen.
  Future<void> write(YtmArtistDetail detail) async {
    _mem[detail.browseId] = detail;
    Timer(const Duration(seconds: 2), () {
      unawaited(_flush(detail));
    });
  }

  /// Marca un browseId como fallado por 10 min: si el screen se reabre
  /// mientras no hay red no relanza la request en cada rebuild.
  void markFailure(String browseId) {
    _failed.add(browseId);
    Timer(const Duration(minutes: 10), () => _failed.remove(browseId));
  }

  Future<void> _flush(YtmArtistDetail detail) async {
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, '${detail.browseId}.json'));
      final data = detailToJson(detail, DateTime.now().millisecondsSinceEpoch);
      await f.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _mem.clear();
    _failed.clear();
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ── (De)serialización ────────────────────────────────────────────────

  static Map<String, dynamic> detailToJson(YtmArtistDetail d, int atMs) => {
    'v': version,
    'at': atMs,
    'id': d.browseId,
    'name': d.name,
    'thumb': d.thumbnailUrl,
    'subs': d.subscriberCount,
    'aud': d.audienceText,
    'tracks': [
      for (final t in d.tracks)
        {
          'id': t.videoId,
          'title': t.title,
          'artist': t.artist,
          'dur': t.durationSeconds,
          'thumb': t.thumbnailUrl,
          'plays': t.playCountText,
        },
    ],
    'albums': [
      for (final a in d.albums)
        {
          'pl': a.playlistId,
          'title': a.title,
          'year': a.year,
          'single': a.isSingle,
          'thumb': a.thumbnailUrl,
        },
    ],
  };

  static YtmArtistDetail? detailFromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final tracks = <YtMusicResult>[];
    if (j['tracks'] is List) {
      for (final e in j['tracks'] as List) {
        if (e is! Map<String, dynamic>) continue;
        final vid = e['id'];
        final title = e['title'];
        if (vid is! String || title is! String) continue;
        tracks.add(
          YtMusicResult(
            videoId: vid,
            title: title,
            artist: e['artist'] is String ? e['artist'] as String : '',
            durationSeconds: e['dur'] is int ? e['dur'] as int : null,
            thumbnailUrl: e['thumb'] is String ? e['thumb'] as String : null,
            playCountText: e['plays'] is String ? e['plays'] as String : null,
          ),
        );
      }
    }
    final albums = <YtmAlbum>[];
    if (j['albums'] is List) {
      for (final e in j['albums'] as List) {
        if (e is! Map<String, dynamic>) continue;
        final pl = e['pl'];
        final title = e['title'];
        if (pl is! String || title is! String) continue;
        albums.add(
          YtmAlbum(
            playlistId: pl,
            title: title,
            year: e['year'] is String ? e['year'] as String : null,
            isSingle: e['single'] == true,
            thumbnailUrl: e['thumb'] is String ? e['thumb'] as String : null,
          ),
        );
      }
    }
    return YtmArtistDetail(
      browseId: id,
      name: j['name'] is String ? j['name'] as String : '',
      thumbnailUrl: j['thumb'] is String ? j['thumb'] as String : null,
      subscriberCount: j['subs'] is int ? j['subs'] as int : null,
      audienceText: j['aud'] is String ? j['aud'] as String : null,
      tracks: tracks,
      albums: albums,
    );
  }
}
