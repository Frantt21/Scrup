import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/track.dart';
import 'search_cache_store.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

export 'ytmusic_service.dart' show YtmArtist;

class SearchService {
  SearchService({
    YtMusicService? ytMusic,
    YtDlpService? ytDlp,
    SearchCacheStore? cache,
  }) : _ytMusic = ytMusic ?? YtMusicService(),
       _ytDlp = ytDlp ?? YtDlpService(),
       _cache = cache;

  final YtMusicService _ytMusic;
  final YtDlpService _ytDlp;

  /// Caché persistente (memoria + disco). `null` = desactivada (tests,
  /// embedded): las búsquedas van siempre a red.
  final SearchCacheStore? _cache;

  // Dedup concurrent searches by key (multiple views / rapid resubmits).
  final Map<String, Future<List<Track>>> _inflight = {};

  /// Límite por defecto de la búsqueda: subido de 10 a 30. InnerTube
  /// responde igual de rápido pidiendo 30 que pidiendo 10 (una request más
  /// grande en la misma respuesta) y la lista scrolleable lo aprovecha.
  static const int defaultLimit = 30;

  /// Búsqueda combinada, en 3 niveles:
  ///
  /// 1. **Caché persistente** (disco): 6h de TTL — las búsquedas repetidas
  ///    (y las de sesiones anteriores) responden al instante.
  /// 2. **InnerTube (YT Music)**: la fuente rápida (~0.3-1s). Sus resultados
  ///    son canciones con metadatos limpios y SIEMPRE llenan el `limit`, así
  ///    que en el caso común son la respuesta completa.
  /// 3. **yt-dlp**: SOLO si InnerTube falló o devolvió menos resultados que
  ///    el límite pedido. Antes corría SIEMPRE en paralelo (~6-8s en Android
  ///    por el arranque de libpython) y su aporte casi nunca llegaba a
  ///    usarse: el merge prioriza canciones y capaba en `limit`, así que con
  ///    InnerTube sano los vídeos de yt-dlp ni entraban — latencia pura.
  ///
  /// Si tras InnerTube se recurre a yt-dlp, el merge pone las canciones
  /// primero y los vídeos rellenan el resto (mismo orden de siempre).
  Future<List<Track>> search(String query, {int? limit}) async {
    final n = limit ?? defaultLimit;
    final q = query.trim();
    if (q.isEmpty) return const [];

    final cached = await _cache?.get(q, n);
    if (cached != null) {
      appLog('SEARCH', 'cache hit "$q" (${cached.length})');
      return cached;
    }

    final inflight = _inflight[q];
    if (inflight != null) return inflight;
    final future = _doSearch(q, n);
    _inflight[q] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(q);
    }
  }

  Future<List<Track>> _doSearch(String q, int limit) async {
    final songs = await _ytMusic
        .search(q, limit: limit)
        .then<List<Track>>(
          (results) => [for (final r in results) r.toTrack()],
          onError: (_) => const <Track>[],
        );

    List<Track> merged = songs;
    if (songs.length < limit) {
      // InnerTube incompleto (fallo de red, respuesta vacía o filtro sin
      // coincidencias): completa con vídeos de yt-dlp. En Android puede
      // tardar varios segundos (toolchain) — es el fallback, no el camino.
      final videos = await _ytDlp
          .search(q, limit: limit)
          .catchError((e) {
            debugPrint('[Search] yt-dlp search failed: $e');
            return <Track>[];
          });
      merged = mergeResults(songs, videos, limit);
    }
    if (merged.isNotEmpty) {
      unawaited(_cache?.put(q, limit, merged));
    }
    return merged;
  }

  /// Recomendaciones para el modo radio: SOLO YouTube Music (InnerTube).
  /// La consulta suele ser el nombre del artista, y el filtro de canciones
  /// de YT Music devuelve pistas canónicas del artista (sin covers, lives
  /// ni mixes que yt-dlp suele colar). Tolerante a fallos: cualquier error
  /// → lista vacía. Cachea (misma TTL de 6h): la radio de un artista no
  /// cambia en horas y evita relanzar la consulta en cada pista.
  Future<List<Track>> recommendByArtist(String query, {int limit = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final cached = await _cache?.getForSource('radio', q, limit);
      if (cached != null) return cached;
      final results = await _ytMusic.search(q, limit: limit);
      final tracks = [for (final r in results) r.toTrack()];
      unawaited(_cache?.put(q, limit, tracks, source: 'radio'));
      return tracks;
    } catch (_) {
      return const [];
    }
  }

  /// Búsqueda de ARTISTAS vía InnerTube (búsqueda general, sección
  /// "Artists"/"Top result"). Tolerante a fallos: error → lista vacía.
  Future<List<YtmArtist>> searchArtists(String query, {int limit = 8}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final cached = await _cache?.getForSource('artists', q, limit);
    if (cached != null) {
      return [
        for (final t in cached)
          if (t.thumbnailUrl != null)
            YtmArtist(
              browseId: t.id,
              name: t.title,
              thumbnailUrl: t.thumbnailUrl,
            ),
      ];
    }
    final artists = await _ytMusic.searchArtists(q, limit: limit);
    if (artists.isNotEmpty && _cache != null) {
      // Reusa el store de Track: id=browseId, title=nombre, thumb=miniatura.
      final asTracks = [
        for (final a in artists)
          Track(
            id: a.browseId,
            title: a.name,
            artist: '',
            thumbnailUrl: a.thumbnailUrl,
          ),
      ];
      unawaited(_cache.put(q, limit, asTracks, source: 'artists'));
    }
    return artists;
  }

  /// Canciones primero y después vídeos generales, descartando ids ya
  /// vistos y capando al límite pedido. Expuesto para tests.
  static List<Track> mergeResults(
    List<Track> songs,
    List<Track> videos,
    int limit,
  ) {
    final out = <Track>[];
    final seen = <String>{};
    for (final t in [...songs, ...videos]) {
      if (t.id.isEmpty || !seen.add(t.id)) continue;
      out.add(t);
      if (out.length >= limit) break;
    }
    return out;
  }
}
