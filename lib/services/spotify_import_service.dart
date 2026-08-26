import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/track.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

/// Pista tal y como viene de una playlist de Spotify (metadatos crudos).
class SpotifyPlaylistTrack {
  const SpotifyPlaylistTrack({
    required this.title,
    required this.artists,
    required this.durationMs,
  });

  final String title;
  final String artists;
  final int durationMs; // 0 si se desconoce.

  String get searchQuery => '$title $artists'.trim();
}

/// Playlist leída del embed público de Spotify.
class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
  });

  final String id;
  final String name;
  final List<SpotifyPlaylistTrack> tracks;
}

/// Resultado de emparejar UNA pista de la playlist contra YouTube.
class SpotifyMatchResult {
  const SpotifyMatchResult(
    this.index,
    this.requested, {
    this.match,
    this.error,
  });

  /// Posición dentro de la playlist original.
  final int index;
  final SpotifyPlaylistTrack requested;
  final Track? match;
  final String? error;

  bool get hasMatch => match != null;
}

/// Error de importación con motivo estable ('invalid-id', 'network',
/// 'not-found', 'parse', 'empty') para mapearlo a mensajes l10n.
class SpotifyImportException implements Exception {
  const SpotifyImportException(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Lee playlists PÚBLICAS de Spotify sin API keys usando el endpoint del
/// embed web (`open.spotify.com/embed/playlist/{id}`), cuyo HTML incrusta un
/// JSON (`__NEXT_DATA__`) con el nombre y las pistas. Después empareja cada
/// pista contra YouTube con yt-dlp para poder crear la playlist en Scrup,
/// donde la fuente siempre es YouTube.
class SpotifyImportService {
  SpotifyImportService({http.Client? client})
    : _client = client ?? http.Client();

  static final _nextDataRe = RegExp(
    r'id="__NEXT_DATA__"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  /// Acepta URL completa (con o sin query, con o sin intl-XX),
  /// URI `spotify:playlist:ID` o el ID pelado base62 de 22 caracteres.
  static String? extractPlaylistId(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final uriMatch = RegExp(r'spotify:playlist:([A-Za-z0-9]+)').firstMatch(s);
    if (uriMatch != null) return uriMatch.group(1);
    final urlMatch = RegExp(
      r'open\.spotify\.com/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?playlist/([A-Za-z0-9]+)',
    ).firstMatch(s);
    if (urlMatch != null) return urlMatch.group(1);
    if (RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(s)) return s;
    return null;
  }

  /// Descarga y parsea el embed público. Lanza [SpotifyImportException] si
  /// el enlace no es válido, la playlist no existe o no es pública.
  Future<SpotifyPlaylist> fetchPlaylist(String urlOrId) async {
    final id = extractPlaylistId(urlOrId);
    if (id == null) throw const SpotifyImportException('invalid-id');
    final uri = Uri.parse('https://open.spotify.com/embed/playlist/$id');
    http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const SpotifyImportException('network');
    }
    if (res.statusCode != 200) throw const SpotifyImportException('not-found');
    return parseEmbedHtml(res.body, expectedId: id);
  }

  /// Parsea el HTML del embed. Expuesto para tests (sin red).
  static SpotifyPlaylist parseEmbedHtml(String html, {String? expectedId}) {
    final m = _nextDataRe.firstMatch(html);
    if (m == null) throw const SpotifyImportException('parse');
    Object? data;
    try {
      data = jsonDecode(m.group(1)!);
    } catch (_) {
      throw const SpotifyImportException('parse');
    }
    final entity = findEntity(data);
    if (entity == null) throw const SpotifyImportException('parse');

    final name = (entity['name'] as String?)?.trim() ?? '';
    final list = entity['trackList'];
    if (list is! List || list.isEmpty) {
      throw const SpotifyImportException('empty');
    }
    final tracks = <SpotifyPlaylistTrack>[];
    for (final item in list) {
      if (item is! Map) continue;
      final title = (item['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;
      var artists = '';
      final rawArtists = item['artists'];
      if (rawArtists is List) {
        artists = rawArtists
            .map((a) => a is Map ? (a['name'] as String? ?? '') : '')
            .where((s) => s.isNotEmpty)
            .join(', ');
      }
      // Algunas versiones del embed no traen artists[] sino subtitle.
      if (artists.isEmpty && item['subtitle'] is String) {
        artists = item['subtitle'] as String;
      }
      final d = item['duration'];
      final durationMs = d is num && d > 0 ? d.round() : 0;
      tracks.add(
        SpotifyPlaylistTrack(
          title: title,
          artists: artists,
          durationMs: durationMs,
        ),
      );
    }
    if (tracks.isEmpty) throw const SpotifyImportException('empty');
    return SpotifyPlaylist(
      id: expectedId ?? '',
      name: name.isEmpty ? 'Spotify' : name,
      tracks: tracks,
    );
  }

  /// Busca recursivamente el primer Map que tenga 'trackList': la ruta
  /// exacta (`props.pageProps.state.data.entity`) cambia entre versiones
  /// del embed, así que no dependemos de ella.
  static Map<String, dynamic>? findEntity(Object? node) {
    if (node is Map) {
      if (node['trackList'] is List) {
        return Map<String, dynamic>.from(node);
      }
      for (final v in node.values) {
        final found = findEntity(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = findEntity(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- matching

  /// Normaliza texto para comparar títulos: minúsculas, solo alfanumérico y
  /// con diacríticos latinos plegados (á→a…).
  static String normalize(String s) {
    final sb = StringBuffer();
    for (final ch in s.toLowerCase().runes) {
      final folded = _fold[ch];
      if (folded != null) {
        sb.writeCharCode(folded);
      } else if ((ch >= 0x30 && ch <= 0x39) || (ch >= 97 && ch <= 122)) {
        sb.writeCharCode(ch);
      }
    }
    return sb.toString();
  }

  static const _fold = <int, int>{
    0xE1: 97, // á -> a
    0xE9: 101, // é -> e
    0xED: 105, // í -> i
    0xF3: 111, // ó -> o
    0xFA: 117, // ú -> u
    0xFC: 117, // ü -> u
    0xF1: 110, // ñ -> n
    0xE0: 97, // à -> a
    0xE8: 101, // è -> e
    0xEC: 105, // ì -> i
    0xF2: 111, // ò -> o
    0xF9: 117, // ù -> u
    0xE2: 97, // â
    0xEA: 101, // ê
    0xEE: 105, // î
    0xF4: 111, // ô
    0xFB: 117, // û
    0xE7: 99, // ç -> c
  };

  /// Similitud de títulos 0..1: igualdad > contención > solape de tokens
  /// (Jaccard). Tolerante a "(Official Video)", "Remasterizado", etc.
  static double titleSimilarity(String a, String b) {
    final na = normalize(a);
    final nb = normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;
    if (na.contains(nb) || nb.contains(na)) return .85;
    final ta = na.split(' ').where((t) => t.isNotEmpty).toSet();
    final tb = nb.split(' ').where((t) => t.isNotEmpty).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.intersection(tb).length;
    return inter / (ta.length + tb.length - inter);
  }

  /// Elige el mejor candidato de YouTube para una pista de Spotify combinando
  /// similitud de título (70%), cercanía de duración (25%) y bonus si el
  /// artista aparece en el candidato (5%). Devuelve null si ninguno supera
  /// el umbral mínimo (mejor omitir que meter basura).
  static Track? pickBestMatch(
    List<Track> candidates,
    SpotifyPlaylistTrack target,
  ) {
    Track? best;
    var bestScore = 0.0;
    for (final c in candidates) {
      var score = titleSimilarity(c.title, target.title) * .7;
      if (target.durationMs > 0 && c.duration != null) {
        final diff =
            (c.duration!.inMilliseconds - target.durationMs).abs() / 1000;
        score += (1 - (diff / 45).clamp(0.0, 1.0)) * .25;
      }
      if (target.artists.isNotEmpty) {
        for (final artist in target.artists.split(',')) {
          final na = normalize(artist);
          if (na.length < 3) continue;
          if (normalize(c.title).contains(na) ||
              normalize(c.artist).contains(na)) {
            score += .05;
            break;
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return bestScore >= .35 ? best : null;
  }

  /// Busca en YouTube Music primero (canciones canónicas con metadatos
  /// limpios, técnica de spotdl); si no devuelve nada o falla, cae al
  /// `ytsearch` genérico de yt-dlp.
  Future<List<Track>> _candidatesFor(
    SpotifyPlaylistTrack target, {
    required YtDlpService ytDlp,
    YtMusicService? ytMusic,
    int limitPerSearch = 5,
  }) async {
    if (ytMusic != null) {
      try {
        final songs = await ytMusic.search(target.searchQuery, limit: 8);
        if (songs.isNotEmpty) {
          return [for (final s in songs) s.toTrack()];
        }
      } catch (_) {
        // Endpoint no oficial: cualquier fallo cae al fallback.
      }
    }
    return ytDlp.search(target.searchQuery, limit: limitPerSearch);
  }

  /// Empareja todas las pistas contra YouTube con un pool de trabajadores
  /// ([concurrency], como DeezerService.enrichAll). Reporta cada resultado
  /// por callback en cuanto termina (sin orden garantizado); devuelve la
  /// lista completa al acabar.
  Future<List<SpotifyMatchResult>> importToYoutube({
    required SpotifyPlaylist playlist,
    required YtDlpService ytDlp,
    YtMusicService? ytMusic,
    void Function(SpotifyMatchResult result)? onResult,
    int concurrency = 2,
    int limitPerSearch = 5,
  }) async {
    final results = List<SpotifyMatchResult?>.filled(
      playlist.tracks.length,
      null,
    );
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= playlist.tracks.length) return;
        final t = playlist.tracks[i];
        try {
          final candidates = await _candidatesFor(
            t,
            ytDlp: ytDlp,
            ytMusic: ytMusic,
            limitPerSearch: limitPerSearch,
          );
          results[i] = SpotifyMatchResult(
            i,
            t,
            match: pickBestMatch(candidates, t),
          );
        } catch (e) {
          results[i] = SpotifyMatchResult(i, t, error: e.toString());
        }
        onResult?.call(results[i]!);
      }
    }

    await Future.wait([for (var w = 0; w < concurrency; w++) worker()]);
    return results.whereType<SpotifyMatchResult>().toList();
  }

  final http.Client _client;
}
