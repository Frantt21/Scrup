import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/track.dart';
import 'artist_cache_store.dart';
import 'search_cache_store.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

export 'ytmusic_service.dart' show YtmAlbum, YtmArtist, YtmArtistDetail;

class SearchService {
  SearchService({
    YtMusicService? ytMusic,
    YtDlpService? ytDlp,
    SearchCacheStore? cache,
    ArtistCacheStore? artistCache,
  }) : _ytMusic = ytMusic ?? YtMusicService(),
       _ytDlp = ytDlp ?? YtDlpService(),
       _cache = cache,
       _artistCache = artistCache;

  final YtMusicService _ytMusic;
  final YtDlpService _ytDlp;

  /// Caché persistente (memoria + disco). `null` = desactivada (tests,
  /// embedded): las búsquedas van siempre a red.
  final SearchCacheStore? _cache;

  /// Caché de detalles de artista (JSON por browseId, TTL 24h). `null` =
  /// desactivada (tests): el detalle va siempre a red.
  final ArtistCacheStore? _artistCache;

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

  /// Deriva los artistas de una búsqueda desde los PROPIOS resultados, sin
  /// ninguna request extra: cada fila de InnerTube trae el canal del artista
  /// en su navegación. Agrupa por canal, cuenta coincidencias y ordena:
  /// 1º por nº de canciones del artista en los resultados (relevancia),
  /// 2º por suscriptores (el resultado más popular del mismo canal). Con
  /// eso no hace falta la búsqueda general de InnerTube (que era una
  /// request ADICIONAL por búsqueda y la encarecía).
  static List<YtmArtist> deriveArtists(List<Track> results, {int limit = 8}) {
    if (results.isEmpty) return const [];
    // Por canal: mejor YtmArtist (más subs vista) + nº de coincidencias.
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
        // SIN avatar aquí a propósito: la única miniatura disponible en la
        // fila es la PORTADA de la canción (mostrarla como cara del canal
        // era el "avatar random" del listado). La real llega al instante
        // desde _artistAvatars y pinta al resolver.
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

  /// Detalle del artista (top canciones + álbumes + suscriptores) con su
  /// PROPIO caché en disco (JSON por artista, TTL 24h — el catálogo de un
  /// artista casi no cambia en un día; entra/salir del screen es gratis).
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
      // Memoiza el fallo 10 min: sin red, reabrir el screen no relanza la
      // request en cada intento.
      _artistCache?.markFailure(id);
      return null;
    }
  }

  /// Tracklist de un álbum para el screen de artista. DOS FORMAS DE ID con
  /// caminos DIFERENTES (verificados contra la API real con curl):
  ///
  /// - `MPREb_…` (álbum/single real de YT Music): browse DIRECTO de la
  ///   página del álbum (`fetchAlbumPage`). Envolverlo como playlist
  ///   (`VL MPREb_…`) devuelve 0 items — era la causa del "sin resultados".
  /// - `VL…`/`PL…` (playlist): lectura estándar con `fetchPlaylist`.
  ///
  /// Cacheado (fuente 'album', TTL 6h — abrir un álbum dos veces es gratis).
  Future<List<Track>> fetchAlbumTracks(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) return const [];
    final cached = await _cache?.getForSource('album', id, 50);
    if (cached != null) return cached;
    try {
      final List<Track> tracks;
      if (id.startsWith('MPREb_')) {
        // Página de álbum: browse directo (retorna las filas del tracklist).
        final rows = await _ytMusic.fetchAlbumPage(id);
        tracks = [for (final r in rows) r.toTrack()];
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

  /// Avatares REALES de los canales derivados (una request por ARTISTA, no
  /// por canción): la fila de búsqueda solo trae la portada de la canción,
  /// nunca la cara del canal. Se consulta la página del canal (WEB_REMIX
  /// home) y se extrae su avatar cuadrado a alta resolución. Errores →
  /// entrada con `null` memoizada 10 min (un canal caído no reintenta).
  ///
  /// En disco NO se cachea: el screen de artista ya trae su avatar y la
  /// llamada completa es una request por artista distinto por búsqueda.
  final Map<String, String?> _avatarMemo = {};
  final Map<String, DateTime> _avatarFailedAt = {};
  final Set<String> _avatarInflight = {};

  Future<Map<String, String?>> _artistAvatars(
    List<YtmArtist> artists,
  ) async {
    final out = <String, String?>{};
    final now = DateTime.now();
    for (final a in artists) {
      final id = a.browseId;
      if (id.isEmpty) continue;
      final failed = _avatarFailedAt[id];
      if (failed != null && now.difference(failed) < const Duration(minutes: 10)) {
        out[id] = null;
        continue;
      }
      final memo = _avatarMemo[id];
      if (memo != null) {
        out[id] = memo;
        continue;
      }
      if (_avatarInflight.add(id)) {
        unawaited(
          () async {
            try {
              final d = await _ytMusic.fetchArtist(id);
              if (d.thumbnailUrl != null && d.thumbnailUrl!.isNotEmpty) {
                _avatarMemo[id] = d.thumbnailUrl;
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
      out[id] = _avatarMemo[id];
    }
    return out;
  }

  /// API pública para la vista de búsqueda: devuelve el mapa actual (los
  /// avatares ya conocidos) y lanza en background la resolución de los que
  /// falten. La vista puede refrescar cuando lleguen nuevas URLs.
  Future<Map<String, String?>> resolveArtistAvatars(
    List<YtmArtist> artists,
  ) => _artistAvatars(artists);

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
