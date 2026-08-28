import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/track.dart';
import 'deezer_service.dart';
import 'ytmusic_service.dart';

typedef MetadataHit = ({Track track, String source});

const int kMaxLookupResults = 20;

/// Multi-source metadata search for the editor.
/// Sources: Deezer, iTunes, InnerTube, Spotify oEmbed.
class MetadataLookupService {
  MetadataLookupService({
    http.Client? client,
    String? userAgent,
    DeezerService? deezer,
  }) : _client = client ?? http.Client(),
       userAgent = userAgent ?? _ua,
       _deezer = deezer ?? DeezerService();

  static const _ua = 'Scrup/0.1 (music player)';
  static final _spotifyUrlRe = RegExp(
    r'https?://open\.spotify\.com/(?:intl-[a-z]{2}/)?track/([A-Za-z0-9]+)',
  );

  final http.Client _client;

  final String userAgent;
  final YtMusicService _ytmusic = YtMusicService();
  final DeezerService _deezer;

  // Searches all public sources. Returns all hits with source badges.
  Future<List<MetadataHit>> search(String query) async {
    final spotifyLink = _spotifyUrlRe.firstMatch(query);
    final textQuery = query.replaceFirst(_spotifyUrlRe, '').trim();
    final effective = textQuery.isEmpty ? query : textQuery;

    final futures = await Future.wait<List<MetadataHit>>([
      _searchDeezer(effective),
      _searchItunes(effective),
      _searchInnerTube(effective),
      if (spotifyLink != null) _fromSpotifyUrl(spotifyLink.group(0)!),
    ]);

    return [
      for (final list in futures) ...list,
    ].take(kMaxLookupResults).toList();
  }

  // ── Deezer ──────────────────────────────────────────────────────────

  Future<List<MetadataHit>> _searchDeezer(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      final t = await _deezer.searchManual(query.trim(), '');
      return t == null ? const [] : [(track: t, source: 'Deezer')];
    } catch (_) {
      return const [];
    }
  }

  // ── Apple Music / iTunes Search ─────────────────────────────────────

  Future<List<MetadataHit>> _searchItunes(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      final uri = Uri.parse('https://itunes.apple.com/search').replace(
        queryParameters: {'term': query, 'entity': 'song', 'limit': '10'},
      );
      final resp = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final node = jsonDecode(resp.body);
      final list = (node is Map ? node['results'] : null) as List?;
      if (list == null) return const [];
      final out = <MetadataHit>[];
      for (final raw in list.whereType<Map>()) {
        final title = (raw['trackName'] ?? '') as String;
        if (title.trim().isEmpty) continue;
        final art = ((raw['artworkUrl100'] ?? '') as String).replaceFirst(
          '100x100',
          '600x600',
        );
        final album = (raw['collectionName'] as String?)?.trim();
        out.add((
          track: Track(
            id: '__itunes__',
            title: title,
            artist: (raw['artistName'] ?? '') as String,
            album: (album != null && album.isNotEmpty) ? album : null,
            thumbnailUrl: art.isEmpty ? null : art,
          ),
          source: 'Apple Music',
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ── InnerTube / YT Music ───────────────────────────────────────────

  Future<List<MetadataHit>> _searchInnerTube(String query) async {
    try {
      final res = await _ytmusic.search(query, limit: 10);
      return [
        for (final r in res)
          (
            track: Track(
              id: '__ytmusic__',
              title: r.title,
              artist: r.artist,
              thumbnailUrl: r.thumbnailUrl,
            ),
            source: 'YT Music',
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ── Spotify oEmbed ──────────────────────────────────────────────────

  Future<List<MetadataHit>> _fromSpotifyUrl(String url) async {
    try {
      final uri = Uri.parse(
        'https://open.spotify.com/oembed',
      ).replace(queryParameters: {'url': url});
      final resp = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final node = jsonDecode(resp.body);
      if (node is! Map) return const [];
      final title = (node['title'] ?? '') as String;
      if (title.trim().isEmpty) return const [];
      final thumb = (node['thumbnail_url'] ?? '') as String?;
      return [
        (
          track: Track(
            id: '__spotify__',
            title: title,
            artist: '',
            thumbnailUrl: (thumb == null || thumb.isEmpty) ? null : thumb,
          ),
          source: 'Spotify',
        ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
