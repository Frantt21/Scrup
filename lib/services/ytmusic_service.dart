import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/track.dart';

class YtMusicResult {
  const YtMusicResult({
    required this.videoId,
    required this.title,
    required this.artist,
    this.durationSeconds,
    this.thumbnailUrl,
    this.channelId,
    this.channelSubscribers,
    this.playCountText,
  });

  final String videoId;
  final String title;
  final String artist;
  final int? durationSeconds;
  final String? thumbnailUrl;

  /// Canal del artista (`UC…`) extraído de la navegación de la fila: con él
  /// se abre el detalle del artista SIN una request extra por resultado.
  final String? channelId;

  /// Suscriptores si la fila los traía (0 si hubo canal pero sin texto).
  final int? channelSubscribers;

  /// Reproducciones/vistas de la fila tal como llegan ("1.2M plays").
  /// `null` si la fila no las traía (p. ej. resultados de búsqueda).
  final String? playCountText;

  Duration? get duration =>
      durationSeconds == null ? null : Duration(seconds: durationSeconds!);

  // Converts to Track. Marks cleanMetadata to skip Deezer overwrite.
  Track toTrack() => Track(
    id: videoId,
    title: title,
    artist: artist.isEmpty ? 'YouTube Music' : artist,
    duration: duration,
    thumbnailUrl: thumbnailUrl,
    cleanMetadata: true,
    artistChannelId: channelId,
    subscriberCount: channelSubscribers,
    playCountText: playCountText,
  );
}

class YtMusicException implements Exception {
  const YtMusicException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Artista encontrado en la búsqueda de InnerTube: canal (`browseId` UC…),
/// nombre y miniatura. No es reproducible por sí mismo: para sonar se
/// busca el catálogo del artista por nombre (filtro Songs de YT Music).
class YtmArtist {
  const YtmArtist({
    required this.browseId,
    required this.name,
    this.thumbnailUrl,
    this.subscriberCount,
  });

  final String browseId;
  final String name;
  final String? thumbnailUrl;

  /// Suscriptores del canal (si la fila los traía). `null` = desconocido.
  final int? subscriberCount;
}

/// Detalle de un artista leído de su página de canal (`browse` de InnerTube):
/// top canciones y álbumes detectados en la página.
class YtmArtistDetail {
  const YtmArtistDetail({
    required this.browseId,
    required this.name,
    required this.tracks,
    required this.albums,
    this.thumbnailUrl,
    this.subscriberCount,
    this.songsParams,
    this.audienceText,
  });

  final String browseId;
  final String name;
  final String? thumbnailUrl;
  final int? subscriberCount;
  final List<YtMusicResult> tracks;
  final List<YtmAlbum> albums;

  /// `params` del tab de canciones detectado en la home: con él se hace una
  /// segunda lectura que trae las canciones con duración y reproducciones.
  final String? songsParams;

  /// "218M monthly audience" del header (métrica real de YT Music).
  final String? audienceText;
}

/// Álbum detectado en la página del artista: playlistId reproducible (se
/// vuelve a leer con `fetchPlaylist`) + miniatura.
class YtmAlbum {
  const YtmAlbum({
    required this.playlistId,
    required this.title,
    this.thumbnailUrl,
    this.year,
  });

  final String playlistId;
  final String title;
  final String? thumbnailUrl;

  /// Año (cuando la fila lo trae).
  final String? year;
}

/// Página de álbum leída con `fetchAlbumPage`: filas del tracklist (SIN
/// miniatura — la API no las trae) + portada/título del header de la
/// página, que el llamador propaga a cada fila.
class YtmAlbumPage {
  const YtmAlbumPage({
    required this.rows,
    this.coverUrl,
    this.title = '',
  });

  final List<YtMusicResult> rows;
  final String? coverUrl;
  final String title;
}

/// Public YouTube/YT Music playlist read via InnerTube browse.
class YtmPlaylist {
  const YtmPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
  });

  final String id;
  final String name;

  final List<Track> tracks;
}

/// YouTube Music search via undocumented InnerTube API.
/// Returns songs with clean metadata. Fallback required on failure.
class YtMusicService {
  YtMusicService({http.Client? client}) : _client = client ?? http.Client();

  static const _endpoint = 'https://music.youtube.com/youtubei/v1/search';
  static const _browseEndpoint = 'https://music.youtube.com/youtubei/v1/browse';
  static const _clientName = 'WEB_REMIX';
  static const _clientVersion = '1.20240403.01.00';

  static const _songsFilterParam = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static final _clockRe = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');
  static final _ytListParamRe = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');
  static final _ytBareIdRe = RegExp(r'^(PL|UU|OL|FL|RD|LL)[A-Za-z0-9_-]{10,}$');

  final http.Client _client;

  Map<String, Object> _context() => {
    'client': {
      'clientName': _clientName,
      'clientVersion': _clientVersion,
      'hl': 'en',
      'gl': 'US',
    },
  };

  Future<List<YtMusicResult>> search(String query, {int limit = 8}) async {
    if (query.trim().isEmpty) return const [];
    final body = jsonEncode({
      'context': _context(),
      'query': query,
      'params': _songsFilterParam,
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_endpoint?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': _clientVersion,
            },
            body: body,
          )
  /// Respuesta de InnerTube. Bajado de 12s a 8s: en el pipeline nuevo
  /// InnerTube es el CAMINO PRINCIPAL de la búsqueda y yt-dlp (lento en
  /// Android) es el fallback — si InnerTube está colgado, esperar 12s antes
  /// de degradar convertía cada búsqueda en ~14s garantizados. Con 8s un
  /// fallo degrada rápido y la búsqueda sigue siendo usable.
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      rethrow;
    } catch (e) {
      throw YtMusicException(e.toString());
    }
    if (res.statusCode != 200) {
      throw YtMusicException('http-${res.statusCode}');
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw const YtMusicException('bad-json');
    }
    return parseResponse(data, limit);
  }

  /// Búsqueda de ARTISTAS en InnerTube: misma query, SIN el filtro de
  /// canciones (`params`) — la respuesta general incluye las secciones
  /// "Top result" y "Artists" cuyos items navegan a canales (browseId
  /// `UC…`). Filtramos por eso: los items con videoId son canciones y se
  /// descartan.
  /// Errores → lista vacía (la búsqueda de canciones sigue funcionando).
  Future<List<YtmArtist>> searchArtists(String query, {int limit = 8}) async {
    if (query.trim().isEmpty) return const [];
    try {
      final body = jsonEncode({
        'context': _context(),
        'query': query,
        // sin 'params': búsqueda general (incluye artistas).
      });
      final res = await _client
          .post(
            Uri.parse('$_endpoint?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': _clientVersion,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      return parseArtists(data, limit);
    } catch (_) {
      return const [];
    }
  }

  /// Extrae artistas (browseId UC…) del árbol de respuesta general.
  static List<YtmArtist> parseArtists(Object? node, int limit) {
    final results = <YtmArtist>[];
    final seen = <String>{};

    void walk(Object? n) {
      if (results.length >= limit) return;
      if (n is Map) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) {
          final a = artistFromListItem(renderer);
          if (a != null && seen.add(a.browseId)) results.add(a);
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  /// Página de canal de un artista (`browseId` UC…) vía InnerTube browse:
  /// nombre, avatar, suscriptores (del header o de una fila), top canciones
  /// y álbumes detectados en la página. El `params` opcional acota el tab
  /// (p. ej. canciones del artista); sin él, la home del canal.
  Future<YtmArtistDetail> fetchArtist(
    String browseId, {
    String? params,
  }) async {
    final body = jsonEncode({
      'context': _context(),
      'browseId': browseId,
      if (params != null) 'params': params,
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_browseEndpoint?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': _clientVersion,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      rethrow;
    } catch (e) {
      throw YtMusicException(e.toString());
    }
    if (res.statusCode != 200) {
      throw YtMusicException('http-${res.statusCode}');
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw const YtMusicException('bad-json');
    }
    return parseArtistPage(data, browseId);
  }

  /// Parsea la página de canal: nombre/avatar/suscriptores del header,
  /// filas de canciones y filas que navegan a playlists (álbumes/singles).
  static YtmArtistDetail parseArtistPage(Object? node, String browseId) {
    String? name;
    String? thumbUrl;
    String? audience;
    final tracks = <YtMusicResult>[];
    final seenTracks = <String>{};
    final albums = <YtmAlbum>[];
    final seenAlbums = <String>{};

    void walk(Object? n) {
      if (n is Map) {
        // Header del canal: nombre, avatar y suscriptores.
        final header = n['musicImmersiveHeaderRenderer'] as Map? ??
            n['musicVisualHeaderRenderer'] as Map?;
        if (header != null) {
          final title = header['title'];
          if (title is Map && title['runs'] is List) {
            final runs = (title['runs'] as List).whereType<Map>().toList();
            if (runs.isNotEmpty) {
              final t = runs.first['text'];
              if (t is String && t.trim().isNotEmpty && name == null) {
                name = t.trim();
              }
            }
          }
          // Avatar: el thumbnail del header es el BANNER (540×225); el
          // cuadrado 544×544 es el último de la lista. _bestSquareThumb lo
          // elige y _hiRes lo pide a 1200.
          thumbUrl ??= _bestSquareThumb(
            _thumbThumbs(header['thumbnail'] as Map?),
          );
          thumbUrl ??= _bestSquareThumb(
            _thumbThumbs(header['foregroundThumbnail'] as Map?),
          );
          // "218M monthly audience" / "audiencia mensual": la métrica que
          // YT Music muestra en el header (los "subscribers" ya no van ahí).
          final mlc = header['monthlyListenerCount'];
          if (mlc is Map && mlc['runs'] is List) {
            final runs = (mlc['runs'] as List).whereType<Map>().toList();
            if (runs.isNotEmpty) {
              final t = runs.first['text'];
              if (t is String && t.trim().isNotEmpty) {
                audience ??= t.trim();
              }
            }
          }
        }
        // Filas de lista: el shelf "Top songs" de la home del artista trae
        // las canciones populares CON REPRODUCCIONES ("2.2B plays") y
        // portada limpia de álbum.
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) {
          final item = renderer;
          final r = resultFromListItem(item);
          // Las filas del shelf NO traen duración (el player la resuelve al
          // montar); el plays-text presente distingue una fila de canción
          // real de una fila de menú/otra cosa.
          if (r != null &&
              (r.durationSeconds != null || r.playCountText != null) &&
              seenTracks.add(r.videoId)) {
            tracks.add(
              YtMusicResult(
                videoId: r.videoId,
                title: r.title,
                artist: r.artist,
                durationSeconds: r.durationSeconds,
                // Portada a resolución alta (w1200) como el resto.
                thumbnailUrl: _hiRes(r.thumbnailUrl),
                channelId: r.channelId,
                channelSubscribers: r.channelSubscribers,
                playCountText: r.playCountText,
              ),
            );
          }
        }
        // Fila de álbum: navega a playlist VL… (o MPRE…), con año.
        final item = renderer is Map ? renderer : null;
        if (item != null) {
          final nav = item['navigationEndpoint'] as Map?;
          final bid = (nav?['browseEndpoint'] as Map?)?['browseId'] as String?;
          if (bid != null && (bid.startsWith('VL') || bid.startsWith('MPRE'))) {
            final plId = bid.startsWith('VL') ? bid.substring(2) : bid;
            final cols = (item['flexColumns'] as List?) ?? const [];
            String? title;
            String? year;
            if (cols.isNotEmpty) {
              final runs = _runsOf(cols.first as Map);
              if (runs.isNotEmpty && runs.first['text'] is String) {
                title = (runs.first['text'] as String).trim();
              }
            }
            if (cols.length > 1) {
              for (final r2 in _runsOf(cols[1] as Map)) {
                final t = (r2['text'] as String?)?.trim() ?? '';
                if (RegExp(r'^(19|20)\d{2}$').hasMatch(t)) year = t;
              }
            }
            if (title != null &&
                title.isNotEmpty &&
                seenAlbums.add(plId) &&
                albums.length < 24) {
              albums.add(
                YtmAlbum(
                  playlistId: plId,
                  title: title,
                  year: year,
                  thumbnailUrl: _hiRes(
                    _bestThumb(_thumbThumbs(item['thumbnail'] as Map?)),
                  ),
                ),
              );
            }
          }
        }
        // Tarjetas de los carruseles del home del artista ("Songs",
        // "Albums", "Singles"): WEB_REMIX usa musicTwoRowItemRenderer, no
        // filas de lista. Sin esto, el detalle sale vacío (solo nombre).
        // NOTA: aquí SOLO se recogen álbumes/singles. Las canciones vienen
        // del tab de canciones (fetchArtistSongs): los carruseles incluyen
        // la sección "Videos", cuyas miniaturas son de YouTube (con banner
        // de canal) — no sirven como portada de canción.
        final twoRow = n['musicTwoRowItemRenderer'];
        if (twoRow is Map) {
          final nav = twoRow['navigationEndpoint'] as Map?;
          final bid = (nav?['browseEndpoint'] as Map?)?['browseId'] as String?;
          final titleText = _firstRunText(twoRow['title'] as Map?);
          // SOLO MPREb_… son álbumes/singles reales. Los VL… que aparecen
          // en la home son mixes (RD…), playlists de usuarios (PL…) o
          // "Featured on" — no álbumes.
          if (bid is String && bid.startsWith('MPREb_') &&
              titleText != null) {
            final plId = bid;
            String? year;
            final subtitle = twoRow['subtitle'];
            if (subtitle is Map && subtitle['runs'] is List) {
              for (final r in (subtitle['runs'] as List).whereType<Map>()) {
                final t = (r['text'] as String?)?.trim() ?? '';
                if (RegExp(r'^(19|20)\d{2}$').hasMatch(t)) year = t;
              }
            }
            if (titleText.isNotEmpty &&
                seenAlbums.add(plId) &&
                albums.length < 24) {
              albums.add(
                YtmAlbum(
                  playlistId: plId,
                  title: titleText,
                  year: year,
                  thumbnailUrl: _hiRes(
                    _bestThumb(_thumbThumbs(twoRow['thumbnailRenderer'] as Map?)),
                  ),
                ),
              );
            }
          }
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return YtmArtistDetail(
      browseId: browseId,
      name: name ?? '',
      thumbnailUrl: _hiRes(thumbUrl),
      audienceText: audience,
      tracks: tracks.take(6).toList(),
      albums: albums,
    );
  }

  /// Miniatura preferente para AVATARES: la última de la lista suele ser la
  /// cuadrada más grande (la primera es el banner ancho del header).
  static String? _bestSquareThumb(List? thumbs) {
    if (thumbs == null || thumbs.isEmpty) return null;
    return (thumbs.last['url'] as String?)?.toString();
  }

  /// Primer `text` de `holder.runs[0]` (títulos/subtítulos de tarjetas).
  static String? _firstRunText(Map? holder) {
    final runs = holder?['runs'];
    if (runs is! List || runs.isEmpty) return null;
    final t = (runs.first as Map)['text'];
    return t is String ? t.trim() : null;
  }

  /// Tab de CANCIONES del artista: `params` del musicCarouselShelfRenderer
  /// "Songs" → browse con filtro de canciones. Devuelve filas con duración
  /// Y REPRODUCCIONES ("1.2M plays") — portadas de álbum limpias y el
  /// número de vistas real por canción.
  Future<List<YtMusicResult>> fetchArtistSongs(
    String browseId,
    String songsParams, {
    int limit = 6,
  }) async {
    final body = jsonEncode({
      'context': _context(),
      'browseId': browseId,
      'params': songsParams,
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_browseEndpoint?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': _clientVersion,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      rethrow;
    } catch (e) {
      throw YtMusicException(e.toString());
    }
    if (res.statusCode != 200) {
      throw YtMusicException('http-${res.statusCode}');
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw const YtMusicException('bad-json');
    }
    final results = <YtMusicResult>[];
    final seen = <String>{};
    void walk(Object? n) {
      if (results.length >= limit && n is! Map) return;
      if (n is Map) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) {
          final r = resultFromListItem(renderer);
          if (r != null && r.durationSeconds != null && seen.add(r.videoId)) {
            results.add(r);
          }
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(data);
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  /// Extrae el `params` del carrusel "Songs" de la home del artista: cada
  /// carrusel con botón "ver todo" navega al tab correspondiente del canal
  /// con su `params`. El de canciones es el ÚLTIMO carrusel cuyo
  /// navigationBrowseId apunta al PROPIO canal (UC…) en la home WEB_REMIX.
  static String? extractSongsParams(Object? node) {
    String? found;
    void walk(Object? n) {
      if (n is Map) {
        final shelf = n['musicCarouselShelfRenderer'];
        if (shelf is Map) {
          final header = shelf['header'];
          if (header is Map) {
            final basic =
                header['musicCarouselShelfBasicHeaderRenderer'] as Map? ??
                header;
            final nav = basic['navigationEndpoint'] as Map?;
            final bid = (nav?['browseEndpoint'] as Map?)?['browseId'];
            final params = (nav?['browseEndpoint'] as Map?)?['params'];
            if (bid is String &&
                bid.startsWith('UC') &&
                params is String &&
                params.isNotEmpty) {
              found = params; // el último de la home es el de canciones
            }
          }
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return found;
  }

  /// Sube la resolución de una miniatura de Google/YT (la mayor disponible
  /// en la página suele ser ~544px; a 1200 se ve nítida en cualquier tamaño).
  static String? _hiRes(String? url) {
    if (url == null || url.isEmpty) return null;
    return Track.hiResThumbnail(url) ?? url;
  }

  /// Miniatura más grande de una fila/lista de thumbnails.
  static String? _bestThumb(List? thumbs) {
    if (thumbs == null || thumbs.isEmpty) return null;
    Map best = thumbs.first;
    var bestW = (best['width'] as num?) ?? 0;
    for (final t in thumbs) {
      if (((t['width'] as num?) ?? 0) > bestW) {
        best = t;
        bestW = (t['width'] as num?) ?? 0;
      }
    }
    return best['url'] is String ? best['url'] as String : null;
  }

  /// `holder.musicThumbnailRenderer.thumbnail.thumbnails` con casts seguros
  /// por paso (sin cadenas de paren imposibles de mantener).
  static List? _thumbThumbs(Map? holder) {
    if (holder == null) return null;
    final renderer = holder['musicThumbnailRenderer'];
    if (renderer is! Map) return null;
    final thumb = renderer['thumbnail'];
    if (thumb is! Map) return null;
    final thumbs = thumb['thumbnails'];
    return thumbs is List ? thumbs : null;
  }

  /// "1.2M subscribers" → 1200000; null si no hay texto de suscriptores.
  static int? parseSubscribers(String text) {
    final m = RegExp(
      r'([\d.,]+)\s*([KMB])?\s*(?:subscribers|suscriptores|abonados|suscripciones)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.replaceAll(',', '.');
    final num = double.tryParse(raw);
    if (num == null) return null;
    final scale = switch (m.group(2)?.toUpperCase()) {
      'K' => 1e3,
      'M' => 1e6,
      'B' => 1e9,
      _ => 1.0,
    };
    return (num * scale).round();
  }

  /// Runs de una columna flex del renderer (lista de Map con `text`).
  static List<Map> _runsOf(Map column) {
    final runs = (((column['musicResponsiveListItemFlexColumnRenderer'] as Map?)?['text']
                as Map?)?['runs']
            as List?)
        ?.whereType<Map>()
        .toList();
    return runs ?? const [];
  }

  /// Artista desde un musicResponsiveListItemRenderer: navegación a canal
  /// (`browseId` UC…) + nombre en la primera columna.
  static YtmArtist? artistFromListItem(Map item) {
    final nav = item['navigationEndpoint'] as Map?;
    final browse = nav?['browseEndpoint'] as Map?;
    final browseId = browse?['browseId'] as String?;
    if (browseId == null || !browseId.startsWith('UC')) return null;
    final columns = (item['flexColumns'] as List?) ?? const [];
    String? name;
    if (columns.isNotEmpty) {
      final runs =
          ((((columns[0] as Map?)?['musicResponsiveListItemFlexColumnRenderer']
                          as Map?)?['text']
                      as Map?)?['runs']
                  as List?)
              ?.whereType<Map>()
              .toList();
      if (runs != null && runs.isNotEmpty && runs.first['text'] is String) {
        name = (runs.first['text'] as String).trim();
      }
    }
    if (name == null || name.isEmpty) return null;
    final thumbUrl = _bestThumb(
      _thumbThumbs(item['thumbnail'] as Map?),
    );
    // Suscriptores: texto tipo "12.3M subscribers" en cualquier columna.
    int? subs;
    for (final col in (item['flexColumns'] as List?) ?? const []) {
      for (final r in _runsOf(col as Map)) {
        final t = (r['text'] as String?)?.trim() ?? '';
        subs ??= parseSubscribers(t);
      }
    }
    return YtmArtist(
      browseId: browseId,
      name: name,
      thumbnailUrl: thumbUrl,
      subscriberCount: subs,
    );
  }

  // Parses InnerTube response by walking the tree for list item renderers.
  static List<YtMusicResult> parseResponse(Object? node, int limit) {
    final results = <YtMusicResult>[];
    final seen = <String>{};

    void walk(Object? n) {
      if (results.length >= limit && n is! Map) return;
      if (n is Map) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) {
          final r = resultFromListItem(renderer);
          if (r != null && seen.add(r.videoId)) results.add(r);
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    if (results.length > limit) {
      return results.sublist(0, limit);
    }
    return results;
  }

  // Extracts result from a musicResponsiveListItemRenderer.
  static YtMusicResult? resultFromListItem(Map item) {
    final videoId =
        (item['playlistItemData'] as Map?)?['videoId'] as String? ??
        (((item['navigationEndpoint'] as Map?)?['watchEndpoint']
                as Map?)?['videoId']
            as String?);
    if (videoId == null || videoId.isEmpty) return null;
    final columns = (item['flexColumns'] as List?) ?? const [];
    String? title;
    var artist = '';
    int? seconds;
    int? subscribers;
    String? channelId;
    String? playCountText;
    // Miniatura: elegir la de mayor resolución disponible.
    final thumbUrl = _bestThumb(
      (((item['thumbnail'] as Map?)?['musicThumbnailRenderer'] as Map?)?['thumbnail']
              as Map?)?['thumbnails'] as List?,
    );
    for (var i = 0; i < columns.length; i++) {
      final runs = _runsOf(columns[i] as Map);
      if (runs.isEmpty) continue;
      final texts = [
        for (final r in runs)
          if (r['text'] is String) r['text'] as String,
      ];
      if (i == 0) {
        title = texts.isNotEmpty ? texts.first : null;
        continue;
      }
        for (final t in texts) {
        final trimmed = t.trim();
        if (_clockRe.hasMatch(trimmed)) {
          seconds ??= _parseClock(trimmed);
        } else if (trimmed.isNotEmpty && artist.isEmpty) {
          artist = trimmed.replaceAll(RegExp(r'\s*[•|]\s*$'), '').trim();
        }
        // La columna del artista puede traer "Artist • 1.2M subscribers".
        subscribers ??= parseSubscribers(trimmed);
        // Reproducciones de la fila (tab de canciones del artista):
        // "1.2M plays" / "345K reproducciones".
        playCountText ??= _parsePlayCount(trimmed);
      }
    }
    // Canal del artista: navegación del PRIMER run de la columna del artista
    // (en YT Music el nombre va con link a browseId UC…). La vista/subs
    // ("1.2M views") NO lleva canal: solo acepta canales.
    for (var i = 1; i < columns.length && channelId == null; i++) {
      for (final r in _runsOf(columns[i] as Map)) {
        final nav = r['navigationEndpoint'] as Map?;
        final bid = (nav?['browseEndpoint'] as Map?)?['browseId'] as String?;
        if (bid != null && bid.startsWith('UC')) {
          channelId = bid;
          break;
        }
      }
    }
    if (subscribers == null && channelId != null) {
      subscribers = 0;
    }
    if (seconds == null) {
      final fixed = (item['fixedColumns'] as List?)?.whereType<Map>();
      for (final col in fixed ?? const <Map>[]) {
        final runs =
            ((((col['musicResponsiveListItemFixedColumnRenderer']
                            as Map?)?['text']
                        as Map?)?['runs']
                    as List?)
                ?.whereType<Map>()
                .toList());
        if (runs == null) continue;
        for (final r in runs) {
          final t = (r['text'] as String?)?.trim();
          if (t != null && _clockRe.hasMatch(t)) {
            seconds = _parseClock(t);
            break;
          }
        }
        if (seconds != null) break;
      }
    }
    if (title == null || title.trim().isEmpty) return null;
    return YtMusicResult(
      videoId: videoId,
      title: title.trim(),
      artist: artist,
      durationSeconds: seconds,
      thumbnailUrl: thumbUrl,
      channelId: channelId,
      channelSubscribers: subscribers,
      playCountText: playCountText,
    );
  }

  /// "1.2M plays" / "345K reproducciones" → texto normalizado; null si no
  /// es un contador de reproducciones (duración, año, etc.).
  static String? _parsePlayCount(String text) {
    final m = RegExp(
      r'^([\d.,]+[KMB]?)\s+(?:plays|reproducciones|views|visualizaciones)$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    return m == null ? null : text.trim();
  }

  // ── Álbumes ─────────────────────────────────────────────────────────

  /// Tracklist de un álbum por su browseId (`MPREb_…` página de álbum o
  /// `VL…`/id de playlist): browse + parseBrowsePage con continuación.
  /// NOTA: el id de `MPREb_X` NO mapea a ninguna playlist `PL…`: la única
  /// vía correcta es navegar la página del álbum directamente.
  ///
  /// IMPORTANTE (verificado contra la API real): las filas del tracklist NO
  /// traen miniatura (solo index/título/artista/duración/plays). La portada
  /// del álbum vive SOLO en el header de la página
  /// (`musicResponsiveHeaderRenderer.thumbnail`) — se devuelve aparte en
  /// [YtmAlbumPage] para que el llamador la propague a cada fila.
  Future<YtmAlbumPage> fetchAlbumPage(String browseIdOrPlaylist) async {
    var id = browseIdOrPlaylist.trim();
    if (id.startsWith('VL')) id = id.substring(2);
    final tracks = <YtMusicResult>[];
    final seen = <String>{};
    String? continuation;
    String? coverUrl;
    String? title;
    for (var page = 0; page < 10 && tracks.length < 100; page++) {
      final body = jsonEncode({
        'context': _context(),
        if (continuation == null) 'browseId': id else 'continuation': continuation,
      });
      http.Response res;
      try {
        res = await _client
            .post(
              Uri.parse('$_browseEndpoint?prettyPrint=false'),
              headers: const {
                'Content-Type': 'application/json',
                'User-Agent': 'Mozilla/5.0',
                'X-YouTube-Client-Name': '67',
                'X-YouTube-Client-Version': _clientVersion,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        throw YtMusicException(e.toString());
      }
      if (res.statusCode != 200) {
        throw YtMusicException('http-${res.statusCode}');
      }
      Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        throw const YtMusicException('bad-json');
      }
      // Portada y título del header (solo la 1ª página los trae).
      coverUrl ??= _pageCoverUrl(data);
      title ??= _pageTitle(data);
      final parsed = parseBrowsePage(data);
      for (final r in parsed.$1) {
        if (seen.add(r.videoId)) tracks.add(r);
      }
      if (parsed.$2 == null || parsed.$1.isEmpty) break;
      continuation = parsed.$2;
    }
    return YtmAlbumPage(
      rows: tracks,
      coverUrl: coverUrl,
      title: title ?? '',
    );
  }

  /// Portada del header de una página de álbum
  /// (`musicResponsiveHeaderRenderer.thumbnail.musicThumbnailRenderer`).
  static String? _pageCoverUrl(Object? node) {
    String? found;
    void walk(Object? n) {
      if (found != null) return;
      if (n is Map) {
        final header = n['musicResponsiveHeaderRenderer'] as Map?;
        if (header != null) {
          final url = _bestThumb(_thumbThumbs(header['thumbnail'] as Map?));
          if (url != null) {
            found = url;
            return;
          }
        }
        for (final v in n.values) {
          walk(v);
        }
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return found;
  }

  /// Título del header de una página de álbum.
  static String? _pageTitle(Object? node) {
    String? found;
    void walk(Object? n) {
      if (found != null) return;
      if (n is Map) {
        final header = n['musicResponsiveHeaderRenderer'] as Map?;
        if (header != null) {
          final title = header['title'];
          if (title is Map) {
            final simple = title['simpleText'];
            if (simple is String && simple.trim().isNotEmpty) {
              found = simple.trim();
              return;
            }
            if (title['runs'] is List) {
              final runs = (title['runs'] as List).whereType<Map>().toList();
              if (runs.isNotEmpty && runs.first['text'] is String) {
                found = (runs.first['text'] as String).trim();
                return;
              }
            }
          }
        }
        for (final v in n.values) {
          walk(v);
        }
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return found;
  }

  // ── Playlists ───────────────────────────────────────────────────────

  static String? extractYoutubePlaylistId(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final param = _ytListParamRe.firstMatch(s);
    if (param != null) return param.group(1);
    if (_ytBareIdRe.hasMatch(s)) return s;
    return null;
  }

  // Reads a public YTM playlist via InnerTube browse (paginated).
  Future<YtmPlaylist> fetchPlaylist(
    String urlOrId, {
    int maxTracks = 2000,
  }) async {
    final id = extractYoutubePlaylistId(urlOrId);
    if (id == null) throw const YtMusicException('invalid-id');
    final tracks = <Track>[];
    final seen = <String>{};
    String? continuation;
    var name = '';
    for (var page = 0; page < 50 && tracks.length < maxTracks; page++) {
      final body = jsonEncode({
        'context': _context(),
        if (continuation == null)
          'browseId': 'VL$id'
        else
          'continuation': continuation,
      });
      http.Response res;
      try {
        res = await _client
            .post(
              Uri.parse('$_browseEndpoint?prettyPrint=false'),
              headers: const {
                'Content-Type': 'application/json',
                'User-Agent': 'Mozilla/5.0',
                'X-YouTube-Client-Name': '67',
                'X-YouTube-Client-Version': _clientVersion,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        rethrow;
      } catch (e) {
        throw YtMusicException(e.toString());
      }
      if (res.statusCode != 200) {
        throw YtMusicException('http-${res.statusCode}');
      }
      Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        throw const YtMusicException('bad-json');
      }
      final parsed = parseBrowsePage(data);
      name = name.isEmpty ? parsed.$3 : name;
      var added = 0;
      for (final r in parsed.$1) {
        if (seen.add(r.videoId)) {
          tracks.add(r.toTrack());
          added++;
        }
      }
      if (parsed.$2 == null || added == 0) break;
      continuation = parsed.$2;
    }
    if (tracks.isEmpty) throw const YtMusicException('empty');
    return YtmPlaylist(id: id, name: name, tracks: tracks);
  }

  // Parses browse page: items + continuation token + header name.
  static (List<YtMusicResult>, String?, String) parseBrowsePage(Object? node) {
    final items = <YtMusicResult>[];
    final seen = <String>{};
    String? continuation;
    var name = '';

    void walk(Object? n) {
      if (n is Map) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) {
          final r = resultFromListItem(renderer);
          if (r != null && seen.add(r.videoId)) items.add(r);
        }
        if (continuation == null) {
          final cont =
              (n['continuationItemRenderer'] as Map?)?['continuationEndpoint']
                  as Map?;
          final token =
              ((cont?['continuationCommand'] as Map?)?['token']) as String?;
          if (token != null && token.isNotEmpty) continuation = token;
        }
        for (final headerKey in const [
          'musicResponsiveHeaderRenderer',
          'playlistHeaderRenderer',
        ]) {
          if (name.isEmpty && n[headerKey] is Map) {
            final header = n[headerKey] as Map;
            final title = header['title'];
            if (title is Map) {
              final simple = title['simpleText'];
              if (simple is String && simple.trim().isNotEmpty) {
                name = simple.trim();
              } else if (title['runs'] is List) {
                final runs = (title['runs'] as List).whereType<Map>().toList();
                if (runs.isNotEmpty && runs.first['text'] is String) {
                  final text = runs.first['text'] as String;
                  if (text.trim().isNotEmpty) name = text.trim();
                }
              }
            }
          }
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return (items, continuation, name);
  }

  static int _parseClock(String s) {
    final parts = s.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p;
    }
    return seconds;
  }

  /// Fetches audio stream URLs from InnerTube player endpoint.
  /// Returns the URL of the best available adaptive audio format.
  /// Used on Android where yt-dlp may not work.
  static const _playerEndpoint = 'https://music.youtube.com/youtubei/v1/player';
  static const _playerApiKey = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

  Future<String?> getAudioStreamUrl(String videoId) async {
    final body = jsonEncode({
      'videoId': videoId,
      'context': _context(),
      'params': 'CgIQBg==',
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_playerEndpoint?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': '1.20240403.01.00',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
    if (res.statusCode != 200) {
      debugPrint('[innertube] player HTTP ${res.statusCode}');
      return null;
    }
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
    final status = data['playabilityStatus']?['status'];
    final reason = data['playabilityStatus']?['reason'] ?? '';
    debugPrint('[innertube] player status=$status reason=$reason');
    if (status != 'OK') return null;
    final streamingData = data['streamingData'];
    if (streamingData == null) return null;
    // Prefer adaptive audio-only formats (lower bitrate first for smaller files).
    final adaptive = streamingData['adaptiveFormats'] as List<dynamic>? ?? [];
    for (final fmt in adaptive) {
      if (fmt is! Map<String, dynamic>) continue;
      final mimeType = fmt['mimeType'] as String? ?? '';
      if (!mimeType.startsWith('audio/')) continue;
      final url = fmt['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    }
    // Fallback: combined formats
    final formats = streamingData['formats'] as List<dynamic>? ?? [];
    for (final fmt in formats) {
      if (fmt is! Map<String, dynamic>) continue;
      final url = fmt['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  void close() => _client.close();
}
