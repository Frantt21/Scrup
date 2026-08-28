import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/track.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

class SpotifyPlaylistTrack {
  const SpotifyPlaylistTrack({
    required this.title,
    required this.artists,
    required this.durationMs,
  });

  final String title;
  final String artists;
  final int durationMs;

  String get searchQuery => '$title $artists'.trim();
}

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

class SpotifyMatchResult {
  const SpotifyMatchResult(
    this.index,
    this.requested, {
    this.match,
    this.error,
  });

  final int index;
  final SpotifyPlaylistTrack requested;
  final Track? match;
  final String? error;

  bool get hasMatch => match != null;
}

class SpotifyImportException implements Exception {
  const SpotifyImportException(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Reads public Spotify playlists via the embed endpoint and matches
/// tracks to YouTube.
class SpotifyImportService {
  SpotifyImportService({http.Client? client})
    : _client = client ?? http.Client();

  static final _nextDataRe = RegExp(
    r'id="__NEXT_DATA__"[^>]*>(.*?)</script>',
    dotAll: true,
  );

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

  // Fetches and parses the public embed. Throws on invalid/deleted/private.
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

  // Recursively finds first Map with 'trackList' key.
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

  // ── Matching ──────────────────────────────────────────────────────

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

  // Picks best YouTube match for a Spotify track.
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

  // Tries YT Music first, falls back to yt-dlp search.
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
      } catch (_) {}
    }
    return ytDlp.search(target.searchQuery, limit: limitPerSearch);
  }

  // Matches all tracks to YouTube with a concurrent worker pool.
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
