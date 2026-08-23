import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/track.dart';

/// Resultado de una búsqueda en YouTube Music.
class YtMusicResult {
  const YtMusicResult({
    required this.videoId,
    required this.title,
    required this.artist,
    this.durationSeconds,
    this.thumbnailUrl,
  });

  /// Mismo espacio de ids que YouTube: reproduce con el pipeline normal.
  final String videoId;
  final String title;
  final String artist;
  final int? durationSeconds;
  final String? thumbnailUrl;

  Duration? get duration => durationSeconds == null
      ? null
      : Duration(seconds: durationSeconds!);

  /// Conversión a Track del pipeline normal (cache/reproducción/deezer).
  Track toTrack() => Track(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'YouTube Music' : artist,
        duration: duration,
        thumbnailUrl: thumbnailUrl,
      );
}

class YtMusicException implements Exception {
  const YtMusicException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Playlist pública de YouTube / YouTube Music leída vía InnerTube browse.
class YtmPlaylist {
  const YtmPlaylist({required this.id, required this.name, required this.tracks});

  final String id;
  final String name;

  /// Tracks listos para el pipeline normal (videoIds exactos: matching 100%).
  final List<Track> tracks;
}

/// Búsqueda en YouTube Music vía la API interna InnerTube (la misma que usa
/// spotdl como backend): no requiere login ni API key y devuelve CANCIONES
/// con metadatos limpios (artista, duración), muy superiores al `ytsearch`
/// genérico de yt-dlp para emparejar pistas de Spotify.
///
/// Es un endpoint no documentado: si falla o cambia, el llamador debe tener
/// un fallback (p. ej. yt-dlp).
class YtMusicService {
  YtMusicService({http.Client? client}) : _client = client ?? http.Client();

  static const _endpoint =
      'https://music.youtube.com/youtubei/v1/search';
  static const _browseEndpoint =
      'https://music.youtube.com/youtubei/v1/browse';
  static const _clientName = 'WEB_REMIX';
  static const _clientVersion = '1.20240403.01.00';
  /// Filtro InnerTube "Songs": solo canciones canónicas, sin vídeos sueltos.
  static const _songsFilterParam = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static final _clockRe = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');
  static final _ytListParamRe = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');
  static final _ytBareIdRe =
      RegExp(r'^(PL|UU|OL|FL|RD|LL)[A-Za-z0-9_-]{10,}$');

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
          .timeout(const Duration(seconds: 12));
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

  /// Parsea la respuesta InnerTube. Expuesto para tests (sin red).
  ///
  /// En vez de seguir la ruta exacta del JSON (cambia entre versiones),
  /// recorre el árbol y recolecta todos los `musicResponsiveListItemRenderer`
  /// que traigan videoId, en orden de aparición: el estante de "Songs"
  /// siempre va primero en la respuesta general.
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

  /// Extrae un resultado de un `musicResponsiveListItemRenderer` (misma
  /// forma de ítem en resultados de búsqueda y playlists). Null si no trae
  /// videoId o título utilizables.
  static YtMusicResult? resultFromListItem(Map item) {
    final videoId =
        (item['playlistItemData'] as Map?)?['videoId'] as String? ??
            (((item['navigationEndpoint'] as Map?)?['watchEndpoint'] as Map?)
                ?['videoId'] as String?);
    if (videoId == null || videoId.isEmpty) return null;
    final columns = (item['flexColumns'] as List?) ?? const [];
    String? title;
    var artist = '';
    int? seconds;
    // Miniatura: elegir la de mayor resolución disponible.
    String? thumbUrl;
    final thumbs = ((((item['thumbnail'] as Map?)?['musicThumbnailRenderer']
                        as Map?)
                    ?['thumbnail'] as Map?)?['thumbnails'] as List?)
        ?.whereType<Map>();
    if (thumbs != null && thumbs.isNotEmpty) {
      Map best = thumbs.first;
      var bestW = (best['width'] as num?) ?? 0;
      for (final t in thumbs) {
        if (((t['width'] as num?) ?? 0) > bestW) {
          best = t;
          bestW = (t['width'] as num?) ?? 0;
        }
      }
      if (best['url'] is String) thumbUrl = best['url'] as String;
    }
    for (var i = 0; i < columns.length; i++) {
      final runs = ((((columns[i] as Map?)?[
                      'musicResponsiveListItemFlexColumnRenderer'] as Map?)
                  ?['text'] as Map?)
              ?['runs'] as List?)
          ?.whereType<Map>()
          .toList();
      if (runs == null || runs.isEmpty) continue;
      final texts = [
        for (final r in runs)
          if (r['text'] is String) r['text'] as String,
      ];
      if (i == 0) {
        title = texts.isNotEmpty ? texts.first : null;
        continue;
      }
      // Columna secundaria: "Artista • Álbum • 3:45" (runs separados).
      for (final t in texts) {
        final trimmed = t.trim();
        if (_clockRe.hasMatch(trimmed)) {
          seconds ??= _parseClock(trimmed);
        } else if (trimmed.isNotEmpty && artist.isEmpty) {
          artist = trimmed.replaceAll(RegExp(r'\s*[•|]\s*$'), '').trim();
        }
      }
    }
    // En playlists la duración vive en fixedColumns (columna de ancho fijo).
    if (seconds == null) {
      final fixed = (item['fixedColumns'] as List?)?.whereType<Map>();
      for (final col in fixed ?? const <Map>[]) {
        final runs = ((((col['musicResponsiveListItemFixedColumnRenderer']
                            as Map?)
                        ?['text'] as Map?)?['runs'] as List?)
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
    );
  }

  // ------------------------------------------------- playlists YouTube/YTM

  /// Acepta URLs con parámetro `list=` (music.youtube.com, youtube.com
  /// watch/result, youtu.be) o el ID pelado (PL…, UU…, OL…).
  static String? extractYoutubePlaylistId(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final param = _ytListParamRe.firstMatch(s);
    if (param != null) return param.group(1);
    if (_ytBareIdRe.hasMatch(s)) return s;
    return null;
  }

  /// Lee una playlist PÚBLICA de YouTube / YouTube Music paginando el
  /// endpoint InnerTube browse (sin límite práctico; [maxTracks] es solo un
  /// seguro). Los videoIds vienen exactos: no hay búsqueda ni matching.
  Future<YtmPlaylist> fetchPlaylist(String urlOrId, {int maxTracks = 2000}) async {
    final id = extractYoutubePlaylistId(urlOrId);
    if (id == null) throw const YtMusicException('invalid-id');
    final tracks = <Track>[];
    final seen = <String>{};
    String? continuation;
    var name = '';
    // 50 páginas x ~100 ítems cubre holgado maxTracks; el corte real lo
    // ponen la ausencia de continuation o un capítulo vacío.
    for (var page = 0; page < 50 && tracks.length < maxTracks; page++) {
      final body = jsonEncode({
        'context': _context(),
        if (continuation == null) 'browseId': 'VL$id' else 'continuation': continuation,
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
      if (res.statusCode != 200) throw YtMusicException('http-${res.statusCode}');
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
      // Sin más páginas o sin progreso real: fin.
      if (parsed.$2 == null || added == 0) break;
      continuation = parsed.$2;
    }
    if (tracks.isEmpty) throw const YtMusicException('empty');
    return YtmPlaylist(id: id, name: name, tracks: tracks);
  }

  /// Parsea una página del browse de playlist: ítems + token de continuación
  /// + título del header. Expuesto para tests (sin red).
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

  /// Convierte "m:ss" u "h:mm:ss" a segundos.
  static int _parseClock(String s) {
    final parts = s.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p;
    }
    return seconds;
  }

  void close() => _client.close();
}
