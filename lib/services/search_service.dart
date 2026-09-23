import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/track.dart';
import 'album_rec_cache_store.dart';
import 'artist_avatar_cache_store.dart';
import 'artist_cache_store.dart';
import 'search_cache_store.dart';
import 'track_info_cache_store.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

export 'ytmusic_service.dart'
    show YtmAlbum, YtmArtist, YtmArtistDetail, YtmTrackCredits;

class SearchService {
  SearchService({
    YtMusicService? ytMusic,
    YtDlpService? ytDlp,
    SearchCacheStore? cache,
    ArtistCacheStore? artistCache,
    ArtistAvatarCacheStore? avatarCache,
    AlbumRecCacheStore? albumRecCache,
    TrackInfoCacheStore? trackInfoCache,
  }) : _ytMusic = ytMusic ?? YtMusicService(),
       _ytDlp = ytDlp ?? YtDlpService(),
       _cache = cache,
       _artistCache = artistCache,
       _avatarCache = avatarCache,
       _albumRecCache = albumRecCache,
       _trackInfoCache = trackInfoCache;

  final YtMusicService _ytMusic;
  final YtDlpService _ytDlp;

  /// Caché persistente (memoria + disco). `null` = desactivada (tests,
  /// embedded): las búsquedas van siempre a red.
  final SearchCacheStore? _cache;

  /// Exposición de solo lectura para el detalle de ajustes (nº de entradas).
  SearchCacheStore? get cache => _cache;

  /// Exposición de solo lectura del store de info por pista (canal
  /// resuelto + créditos) para vistas fuera del pipeline de búsqueda.
  TrackInfoCacheStore? get trackInfoCache => _trackInfoCache;

  /// Exposición de solo lectura de la caché de avatares de canal.
  ArtistAvatarCacheStore? get avatarCache => _avatarCache;

  /// Caché de detalles de artista (JSON por browseId, TTL 24h). `null` =
  /// desactivada (tests): el detalle va siempre a red.
  final ArtistCacheStore? _artistCache;

  /// Caché PERSISTENTE de avatares de canal (disco). `null` = desactivada
  /// (tests): los avatares van siempre a red.
  final ArtistAvatarCacheStore? _avatarCache;

  /// Persistent cache of home library-album recommendations (disk). `null` =
  /// disabled (tests): the recommendation row always goes to network.
  final AlbumRecCacheStore? _albumRecCache;

  /// Persistent per-track cache (resolved channel + credits, disk). `null` =
  /// disabled (tests): every lookup goes to network.
  final TrackInfoCacheStore? _trackInfoCache;

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
      // Android first-play fast path: presolve the cached results too (the
      // persistent cache outlives the in-memory URL cache by hours).
      unawaited(
        _ytDlp.preResolveUrls(cached.map((t) => t.id).toList()),
      );
      return cached;
    }

    final inflight = _inflight[q];
    if (inflight != null) return inflight;
    final future = _doSearch(q, n);
    _inflight[q] = future;
    try {
      final tracks = await future;
      // Android first-play fast path: batch-resolve the streaming URLs of
      // the results in ONE yt-dlp run so a later play skips the ~9s python
      // boot. Fire-and-forget; desktop ignores it.
      unawaited(
        _ytDlp.preResolveUrls(tracks.map((t) => t.id).toList()),
      );
      return tracks;
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

  /// Recommendations for radio mode: ONLY YouTube Music (InnerTube).
  /// The query is usually the artist name, and YT Music's songs filter returns
  /// canonical artist tracks (without the covers, lives, and mixes that yt-dlp
  /// tends to include). Fault-tolerant: any error -> empty list. Cached (same
  /// 6h TTL): an artist's radio does not change within hours and avoids re-running
  /// the query on every track.
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

  /// Artist-only InnerTube search (delegates to YtMusicService): used by
  /// the queue panel to resolve a channel id from the track's artist name.
  Future<List<YtmArtist>> searchArtists(String query, {int limit = 8}) =>
      _ytMusic.searchArtists(query, limit: limit);

  /// AUTHORITATIVE channel for a track videoId (InnerTube `next` page —
  /// the same source the YT Music player uses). (browseId, channelName).
  /// A track's owner NEVER changes → cached on disk per videoId, forever.
  Future<(String, String)?> fetchTrackChannel(String videoId) async {
    final id = videoId.trim();
    if (id.isEmpty) return null;
    final cached = await _trackInfoCache?.readChannel(id);
    if (cached != null) return cached;
    final owner = await _ytMusic.fetchTrackChannel(id);
    if (owner != null) {
      _trackInfoCache?.writeChannel(id, owner.$1, owner.$2);
    }
    return owner;
  }

  /// Official credits (YT Music "Song credits" dialog, or auto-generated
  /// description); null when the track has neither or the request fails.
  Future<YtmTrackCredits?> fetchTrackCredits(String videoId) =>
      _ytMusic.fetchTrackCredits(videoId);

  /// Credits with the SAME resolution mechanism as the artist channel:
  /// 1) direct lookup for the cached track's videoId; 2) if the cached id
  /// carries no credits, InnerTube Songs search for "artist title" and the
  /// first hit whose videoId DOES have credits (results are
  /// relevance-ordered, so the first with credits is the official release).
  /// Credits are FIXED at release → cached on disk per videoId (keyed by
  /// the track that was resolved, so repeated plays are instant). Null when
  /// neither path yields anything.
  Future<YtmTrackCredits?> resolveTrackCredits(
    String videoId,
    String title,
    String artist,
  ) async {
    final id = videoId.trim();
    final cached = await _trackInfoCache?.readCredits(id);
    if (cached != null) return cached;
    final resolved = await _resolveTrackCreditsUncached(id, title, artist);
    if (resolved != null) {
      _trackInfoCache?.writeCredits(id, resolved);
    }
    return resolved;
  }

  Future<YtmTrackCredits?> _resolveTrackCreditsUncached(
    String videoId,
    String title,
    String artist,
  ) async {
    final direct = await fetchTrackCredits(videoId).catchError((_) => null);
    if (direct != null) return direct;
    final query = '${artist.trim()} ${title.trim()}'.trim();
    if (query.isEmpty) return null;
    try {
      final hits = await _ytMusic.search(query, limit: 5);
      for (final hit in hits) {
        final credits = await fetchTrackCredits(hit.videoId);
        if (credits != null) return credits;
      }
    } catch (_) {}
    return null;
  }

  /// Derive artists from a search using ONLY the search results, with no extra request: each InnerTube row carries the artist channel in its navigation. Group by channel, count matches, and sort by 1st number of songs by that artist in the results (relevance), 2nd subscribers (the most popular result of the same channel). This avoids the general InnerTube search (which was an extra request per search and made searches slower).
  static List<YtmArtist> deriveArtists(List<Track> results, {int limit = 8}) {
    if (results.isEmpty) return const [];
    // By channel: best YtmArtist (most subs seen) + number of matches.
    final byChannel = <String, ({int hits, YtmArtist artist})>{};
    for (final t in results) {
      final ch = t.artistChannelId;
      if (ch == null || ch.isEmpty) continue;
      final name = t.artist.trim();
      if (name.isEmpty || name.toLowerCase() == 'youtube music') continue;
      final prev = byChannel[ch];
      final subs = (t.subscriberCount ?? 0) > (prev?.artist.subscriberCount ?? 0)
          ? t.subscriberCount
          : prev?.artist.subscriberCount;
      byChannel[ch] = (
        hits: (prev?.hits ?? 0) + 1,
        // NO avatar here by design: the only thumbnail available in the row is the SONG COVER (showing it as the channel face was the "random avatar" in the list). The real one arrives instantly from _artistAvatars and paints on resolve.
        artist: YtmArtist(
          browseId: ch,
          name: name,
          subscriberCount: subs,
        ),
      );
    }
    final artists = byChannel.values.toList()
      ..sort((a, b) {
        final byHits = b.hits.compareTo(a.hits);
        if (byHits != 0) return byHits;
        return (b.artist.subscriberCount ?? 0)
            .compareTo(a.artist.subscriberCount ?? 0);
      });
    return [
      for (final e in artists.take(limit)) e.artist,
    ];
  }

  /// Artist detail ALREADY IN MEMORY of this session (no I/O): the screen
  /// paints its FIRST frame with real data — `fetchArtistDetail` is async
  /// and answers one frame late even with a hot cache (placeholder flash).
  YtmArtistDetail? peekArtistDetail(String browseId) =>
      _artistCache?.peekSync(browseId.trim());

  /// Artist detail (top songs + albums + subscribers) with its OWN on-disk cache (one JSON per artist, 24h TTL - the catalog of an artist almost never changes in a day; entering/leaving the screen is cheap).
  Future<YtmArtistDetail?> fetchArtistDetail(
    String browseId, {
    String? name,
  }) async {
    final id = browseId.trim();
    if (id.isEmpty) return null;
    final cached = await _artistCache?.read(id);
    if (cached != null) return cached;
    try {
      var detail = await _ytMusic.fetchArtist(id);
      if (detail.name.isEmpty && name != null) {
        detail = YtmArtistDetail(
          browseId: detail.browseId,
          name: name,
          thumbnailUrl: detail.thumbnailUrl,
          subscriberCount: detail.subscriberCount,
          tracks: detail.tracks,
          albums: detail.albums,
          audienceText: detail.audienceText,
        );
      }
      // Una SOLA request: la home WEB_REMIX ya trae el shelf "Top songs"
      // (con reproducciones y portada limpia) y los carruseles de álbumes.
      if (detail.tracks.isNotEmpty || detail.albums.isNotEmpty) {
        unawaited(_artistCache?.write(detail));
      }
      return detail;
    } catch (_) {
    // Memoize the failure for 10 min: without network, reopening the screen does not re-launch the request on every try.
      _artistCache?.markFailure(id);
      return null;
    }
  }

  /// Tracklist of an album for the artist screen. TWO ID forms with DIFFERENT paths (verified against the real API with curl):
  ///
  /// - `MPREb_...` (real YT Music album/single): DIRECT browse of the album page (`fetchAlbumPage`). Wrapping it as a playlist (`VL MPREb_...`) returns 0 items - that was the cause of "no results".
  /// - `VL...`/`PL...` (playlist): standard read with `fetchPlaylist`.
  ///
  /// Cached (source 'album', 6h TTL - opening an album twice is free).
  Future<List<Track>> fetchAlbumTracks(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) return const [];
    final cached = await _cache?.getForSource('album', id, 50);
    if (cached != null) return cached;
    return _fetchAlbumTracksUncached(id);
  }

  /// Lee el tracklist de InnerTube SIN consultar caché (y cachea el
  /// resultado). Las filas NO traen miniatura (la API solo la expone en el
  /// header de la página) → se propaga la portada del álbum a cada pista.
  Future<List<Track>> _fetchAlbumTracksUncached(String id) async {
    try {
      final List<Track> tracks;
      if (id.startsWith('MPREb_')) {
        final page = await _ytMusic.fetchAlbumPage(id);
        tracks = [
          for (final r in page.rows)
            r.toTrack().copyWith(
              album: page.title.isNotEmpty ? page.title : null,
              thumbnailUrl: page.coverUrl,
            ),
        ];
      } else {
        final pl = await _ytMusic.fetchPlaylist(id, maxTracks: 50);
        tracks = pl.tracks.take(50).toList();
      }
      if (tracks.isNotEmpty) {
        unawaited(_cache?.put(id, 50, tracks, source: 'album'));
        return tracks;
      }
    } catch (_) {
      // Red rota / id inválido: sin resultados.
    }
    return const [];
  }

  /// Home "albums from your library" section: for each (album, artist) pair
  /// found in the user's saved tracks (playlists + favorites, deduped, most
  /// repeated first), find the REAL YT Music album via the InnerTube albums
  /// filter. Returns up to [limit] unique albums, preserving seed order.
  /// Cached per source key with the standard 6h TTL. Fault-tolerant: any
  /// error / empty seeds -> empty list (the section just hides).
  Future<List<YtmAlbum>> recommendedAlbumsFromLibrary(
    List<(String, String)> seeds, {
    int limit = 8,
  }) async {
    if (seeds.isEmpty) return const [];
    final key = seeds
        .take(6)
        .map((s) => '${s.$1}|${s.$2}')
        .join(';;');
    // Persistent cache: the seed set changes rarely and each miss costs one
    // InnerTube request per seed. Disk serves previous sessions instantly.
    final store = _albumRecCache;
    final cached = await store?.get(key);
    if (cached != null) return _albumsFromCacheRows(cached);
    try {
      final albums = <YtmAlbum>[];
      final seenTitles = <String>{};
      for (final (album, artist) in seeds) {
        if (albums.length >= limit) break;
        final found = await _ytMusic.searchAlbums('$album $artist', limit: 1);
        for (final a in found) {
          final k = a.title.toLowerCase();
          if (seenTitles.add(k)) albums.add(a);
        }
      }
      final out = albums.take(limit).toList();
      if (out.isNotEmpty) {
        unawaited(
          store?.put(
            key,
            [
              for (final a in out)
                {
                  'id': a.playlistId,
                  'title': a.title,
                  'thumb': a.thumbnailUrl ?? '',
                  'year': a.year ?? '',
                },
            ],
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Rebuilds [YtmAlbum]s from the cached raw rows.
  List<YtmAlbum> _albumsFromCacheRows(List<Map<String, String>> rows) => [
    for (final r in rows)
      YtmAlbum(
        playlistId: r['id'] ?? '',
        title: r['title'] ?? '',
        thumbnailUrl: (r['thumb'] ?? '').isEmpty ? null : r['thumb'],
        year: (r['year'] ?? '').isEmpty ? null : r['year'],
      ),
  ];

  /// Reload the tracklist by FORCING a re-read of InnerTube (clears the cache entry first). Used by "Reload artworks" in the album screen: it fetches the current header cover and refreshes the thumbnails.
  Future<List<Track>> reloadAlbumTracks(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) return const [];
    await _cache?.removeForSource('album', id, 50);
    return _fetchAlbumTracksUncached(id);
  }

  /// Weekly trending songs (YT Music charts) for the home row. Cached with
  /// the standard TTL: the chart refreshes daily, so a few hours of reuse
  /// costs nothing in freshness. Fault-tolerant: any error -> empty list
  /// (the section just hides).
  Future<List<Track>> fetchWeeklyTrending({int limit = 14}) async {
    const key = 'weekly-trending';
    final cached = await _cache?.getForSource('trending', key, limit);
    if (cached != null) return cached;
    final tracks = await _ytMusic.fetchWeeklyTrending(limit: limit);
    if (tracks.isNotEmpty) {
      unawaited(_cache?.put(key, limit, tracks, source: 'trending'));
    }
    return tracks;
  }

  /// Avatares REALES de los canales derivados (una request por ARTISTA, no
  /// por canción): la fila de búsqueda solo trae la portada de la canción,
  /// nunca la cara del canal. Se consulta la página del canal (WEB_REMIX
  /// home) y se extrae su avatar cuadrado a alta resolución. Errores →
  /// entrada con `null` memoizada 10 min (un canal caído no reintenta).
  ///
  /// En disco NO se cachea: el screen de artista ya trae su avatar y la
  /// llamada completa es una request por artista distinto por búsqueda.
  final Map<String, String> _avatarMemo = {};
  final Map<String, DateTime> _avatarFailedAt = {};
  final Set<String> _avatarInflight = {};

  Future<Map<String, String?>> _artistAvatars(
    List<YtmArtist> artists, {
    void Function(String browseId, String url)? onUpdated,
  }    ) async {
    final out = <String, String?>{};
    for (final a in artists) {
      final id = a.browseId;
      if (id.isEmpty) continue;
      var url = _avatarMemo[id];
      if (url == null) {
        // Disk: the previous session's avatar appears INSTANTLY.
        final cached = await _avatarCache?.get(id);
        if (cached != null) {
          _avatarMemo[id] = cached;
          url = cached;
        }
      }
      out[id] = url;
    }
    // REVALIDACIÓN en background (NO se espera): una request por artista
    // aún no confirmado en vivo esta sesión; si el canal cambió su avatar,
    // se actualiza memoria + disco y se avisa a la vista para repintar.
    unawaited(_revalidateAvatars(artists, onUpdated));
    return out;
  }

  /// Revalida los avatares en background (dedup por canal y por sesión: un
  /// canal ya confirmado en vivo no se vuelve a pedir).
  Future<void> _revalidateAvatars(
    List<YtmArtist> artists,
    void Function(String browseId, String url)? onUpdated,
  ) async {
    final pending = <Future<void>>[];
    final now = DateTime.now();
    for (final a in artists) {
      final id = a.browseId;
      if (id.isEmpty) continue;
      if (_avatarLive.contains(id)) continue; // ya validado en vivo
      final failed = _avatarFailedAt[id];
      if (failed != null &&
          now.difference(failed) < const Duration(minutes: 10)) {
        continue;
      }
      if (_avatarInflight.add(id)) {
        pending.add(
          () async {
            try {
              final d = await _ytMusic.fetchArtist(id);
              final url = d.thumbnailUrl;
              if (url != null && url.isNotEmpty) {
                _avatarLive.add(id);
                final prev = _avatarMemo[id];
                _avatarMemo[id] = url;
                unawaited(_avatarCache?.put(id, url));
                if (prev != null && prev != url) onUpdated?.call(id, url);
              } else {
                _avatarFailedAt[id] = DateTime.now();
              }
            } catch (_) {
              _avatarFailedAt[id] = DateTime.now();
            } finally {
              _avatarInflight.remove(id);
            }
          }(),
        );
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  /// Canales cuyo avatar ya se obtuvo EN VIVO esta sesión (no se revalida
  /// de nuevo hasta reiniciar la app).
  final Set<String> _avatarLive = {};

  /// API pública para la vista de búsqueda: devuelve los avatares ya
  /// conocidos (memoria/disco, instantáneo) y lanza la revalidación en
  /// background. [onUpdated] avisa a la vista cuando un canal cambió su
  /// avatar para que repinte solo esa fila.
  Future<Map<String, String?>> resolveArtistAvatars(
    List<YtmArtist> artists, {
    void Function(String browseId, String url)? onUpdated,
  }) => _artistAvatars(artists, onUpdated: onUpdated);

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
