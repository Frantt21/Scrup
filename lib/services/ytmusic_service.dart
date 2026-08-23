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
  static const _clientName = 'WEB_REMIX';
  static const _clientVersion = '1.20240403.01.00';
  /// Filtro InnerTube "Songs": solo canciones canónicas, sin vídeos sueltos.
  static const _songsFilterParam = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static final _clockRe = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');

  final http.Client _client;

  Future<List<YtMusicResult>> search(String query, {int limit = 8}) async {
    if (query.trim().isEmpty) return const [];
    final body = jsonEncode({
      'context': {
        'client': {
          'clientName': _clientName,
          'clientVersion': _clientVersion,
          'hl': 'en',
          'gl': 'US',
        },
      },
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

    void handleItem(Map item) {
      final videoId =
          (item['playlistItemData'] as Map?)?['videoId'] as String? ??
              (((item['navigationEndpoint'] as Map?)?['watchEndpoint'] as Map?)
                  ?['videoId'] as String?);
      if (videoId == null || videoId.isEmpty || seen.contains(videoId)) {
        return;
      }
      final columns = (item['flexColumns'] as List?) ?? const [];
      String? title;
      String artist = '';
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
      if (title == null || title.trim().isEmpty) return;
      seen.add(videoId);
      results.add(
        YtMusicResult(
          videoId: videoId,
          title: title.trim(),
          artist: artist,
          durationSeconds: seconds,
          thumbnailUrl: thumbUrl,
        ),
      );
    }

    void walk(Object? n) {
      if (results.length >= limit && n is! Map) return;
      if (n is Map) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map) handleItem(renderer);
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
