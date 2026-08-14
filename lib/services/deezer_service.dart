import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/track.dart';

/// Enriquece los metadatos de una pista de YouTube consultando la API
/// pública de Deezer (sin API key): título/artista/álbum limpios y la
/// portada del álbum en alta resolución.
///
/// Es *best-effort*: si no hay una coincidencia fiable, devuelve `null` y
/// la app se queda con los metadatos originales de YouTube.
class DeezerService {
  DeezerService({http.Client? client, this.userAgent = _defaultUserAgent})
    : _client = client ?? http.Client();

  static const _searchUrl = 'https://api.deezer.com/search';
  static const _defaultUserAgent =
      'Scrup/0.1 (music player; +https://github.com/scrup)';

  final http.Client _client;
  final String userAgent;

  /// Caché por id de video de YouTube: evita repetir peticiones a Deezer
  /// cuando la misma pista vuelve a sonar en la sesión.
  final Map<String, Track?> _cache = {};

  /// Descargas en curso por id de video (dedupe de llamadas concurrentes).
  final Map<String, Future<Track?>> _inflight = {};

  /// Busca metadatos en Deezer para [track] y devuelve una versión
  /// enriquecida, o `null` si no encuentra una coincidencia fiable.
  Future<Track?> enrich(Track track) async {
    if (_cache.containsKey(track.id)) return _cache[track.id];
    final inFlight = _inflight[track.id];
    if (inFlight != null) return inFlight;

    final future = _searchAndPick(track);
    _inflight[track.id] = future;
    try {
      final result = await future;
      _cache[track.id] = result;
      return result;
    } finally {
      _inflight.remove(track.id);
    }
  }

  /// Busca en Deezer con un título y artista ESCRITOS A MANO (editor de
  /// metadatos), SIN pasar por la caché por videoId: si el usuario corrige
  /// el artista/título, la búsqueda debe consultar la API de nuevo, no
  /// repetir el resultado (o el `null`) que ya quedó cacheado para ese
  /// video. Devuelve la metadata candidata, o `null` sin coincidencia
  /// fiable.
  Future<Track?> searchManual(String title, String artist) async {
    final probe = Track(id: '__manual__', title: title, artist: artist);
    return _searchAndPick(probe);
  }

  /// Enriquece una lista de pistas en paralelo (con límite de concurrencia
  /// para no saturar la API) y devuelve las pistas ya fusionadas con la
  /// metadata de Deezer cuando hay coincidencia fiable, o la original en
  /// caso contrario. Reutiliza la caché por videoId, así que reproducir
  /// después no repite peticiones.
  Future<List<Track>> enrichAll(
    List<Track> tracks, {
    int concurrency = 4,
  }) async {
    if (tracks.isEmpty) return tracks;

    final enriched = List<Track?>.filled(tracks.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= tracks.length) return;
        final original = tracks[i];
        final deezer = await enrich(original);
        enriched[i] =
            deezer == null ? original : apply(original, deezer) ?? original;
      }
    }

    await Future.wait(
      List.generate(
        concurrency.clamp(1, tracks.length),
        (_) => worker(),
      ),
    );
    return enriched.whereType<Track>().toList();
  }

  Future<Track?> _searchAndPick(Track track) async {
    final query = [
      track.artist,
      track.title,
    ].where((s) => s.trim().isNotEmpty).join(' ');
    if (query.trim().isEmpty) return null;

    try {
      final uri = Uri.parse(
        _searchUrl,
      ).replace(queryParameters: {'q': query, 'limit': '5'});
      final resp = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;

      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      return _pickBest(track, data);
    } catch (_) {
      // Sin red, rate-limit, JSON raro... el enriquecimiento nunca debe
      // interrumpir la reproducción.
      return null;
    }
  }

  /// Elige la coincidencia más fiable entre los resultados de Deezer y la
  /// pista original. Reglas anti-falsos positivos:
  /// - Puntuación mínima (artista+ título) de 2.
  /// - Alguna señal de título (no sobreescribir con otra canción del mismo
  ///   artista). Se exime solo si el original no trae artista.
  Track? _pickBest(Track track, List<dynamic> data) {
    Track? best;
    var bestScore = 0;
    final artistEmpty = track.artist.trim().isEmpty;
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      final candidate = _candidateFrom(item);
      if (candidate == null) continue;
      final (score, titleScore) = _score(track, candidate);
      if ((titleScore >= 1 || artistEmpty) && score >= 2 && score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  Track? _candidateFrom(Map<String, dynamic> item) {
    final artist = (item['artist'] as Map<String, dynamic>?)?['name'];
    final album = (item['album'] as Map<String, dynamic>?)?['title'];
    final md5 = item['md5_image'] as String?;
    final title = item['title'] as String?;
    if (title == null) return null;
    return Track(
      id: '',
      title: title,
      artist: artist as String? ?? '',
      album: album as String?,
      thumbnailUrl: md5 != null && md5.isNotEmpty
          ? 'https://e-cdns-images.dzcdn.net/images/cover/$md5/'
                '500x500-000000-80-0-0.jpg'
          : null,
    );
  }

  /// Similitud aproximada. Devuelve `(score, titleScore)`: el artista exacto
  /// vale 3, el parcial 2; el título exacto 2, el parcial 1.
  (int, int) _score(Track original, Track candidate) {
    final a = _norm(original.artist);
    final b = _norm(original.title);
    final ca = _norm(candidate.artist);
    final cb = _norm(candidate.title);

    var artistScore = 0;
    if (a.isNotEmpty) {
      if (ca == a) {
        artistScore += 3;
      } else if (ca.contains(a) || a.contains(ca)) {
        artistScore += 2;
      }
    }
    var titleScore = 0;
    if (b.isNotEmpty) {
      if (cb == b) {
        titleScore += 2;
      } else if (cb.contains(b) || b.contains(cb)) {
        titleScore += 1;
      }
    }
    return (artistScore + titleScore, titleScore);
  }

  /// Normaliza para comparar: minúsculas, sin diacríticos, sin puntuación,
  /// sin espacios extra. ("Música" → "musica", "Café" → "cafe".)
  static const Map<String, String> _diacritics = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ñ': 'n',
    'ç': 'c',
    'ø': 'o',
    'æ': 'ae',
    'œ': 'oe',
    'ß': 'ss',
  };

  static String _norm(String s) {
    var out = s.toLowerCase();
    _diacritics.forEach((k, v) => out = out.replaceAll(k, v));
    return out
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Devuelve un [Track] enriquecido a partir del original (mantiene el id
  /// de YouTube y la duración) o `null` si no se encontró coincidencia.
  Track? apply(Track original, Track? deezer) {
    if (deezer == null) return null;
    return original.copyWith(
      title: deezer.title,
      // Si Deezer no trae artista, conservar el de YouTube
      artist: deezer.artist.trim().isEmpty ? original.artist : deezer.artist,
      thumbnailUrl: deezer.thumbnailUrl,
      album: deezer.album,
    );
  }
}
