import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'spotify_import_service.dart'
    show SpotifyImportException, SpotifyPlaylist, SpotifyPlaylistTrack;

/// Reads public Apple Music playlists from the web player (no auth) and
/// matches tracks to YouTube reusing the Spotify import pipeline.
///
/// How it works (verified 2026-09 against real playlists of 38/50/300
/// tracks): `GET music.apple.com/<store>/playlist/<slug>/<pl.id>` returns
/// the web player HTML, which embeds the FULL page state in a
/// `<script id="serialized-server-data">` JSON blob:
///
///   data[0].data.sections[] →
///     - id containing "playlist-detail-header": items[0] has the playlist
///       `title` and its declared `trackCount`.
///     - itemKind == "trackLockup": items[] with `title`, `artistName`,
///       `duration` (ms) and album in `tertiaryLinks[0].title`.
///
/// The user playlist ids are case-sensitive (`pl.u-25rzu8zyLJj`); URLs
/// without slug resolve fine and redirects are followed by the http client.
class AppleMusicImportService {
  AppleMusicImportService({http.Client? client})
    : _client = client ?? http.Client();

  static final _playlistIdRe = RegExp(
    r'music\.apple\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?playlist(?:/[^\s/]*)?/'
    r'(pl\.[A-Za-z0-9-]+)',
  );

  static final _bareIdRe = RegExp(r'^pl\.[A-Za-z0-9-]+$');

  static final _serverDataRe = RegExp(
    r'id="serialized-server-data"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  /// Ceiling observed in the initial HTML of the web player (lazy-load).
  /// Playlists above this size are truncated on Apple's side; the declared
  /// `trackCount` lets the UI warn the user (see [SpotifyPlaylist.declaredTrackCount]).
  static const int maxTracks = 300;

  static String? extractPlaylistId(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final m = _playlistIdRe.firstMatch(s);
    if (m != null) return m.group(1);
    if (_bareIdRe.hasMatch(s)) return s;
    return null;
  }

  // Fetch and parse the web player page. Throws on invalid/deleted/private.
  Future<SpotifyPlaylist> fetchPlaylist(String urlOrId) async {
    final id = extractPlaylistId(urlOrId);
    if (id == null) throw const SpotifyImportException('invalid-id');
    // El slug es cosmético: el servidor resuelve /playlist/<id> igual.
    final uri = Uri.parse('https://music.apple.com/us/playlist/$id');
    http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const SpotifyImportException('network');
    }
    if (res.statusCode != 200) throw const SpotifyImportException('not-found');
    return parseHtml(res.body, expectedId: id);
  }

  static SpotifyPlaylist parseHtml(String html, {String? expectedId}) {
    final m = _serverDataRe.firstMatch(html);
    if (m == null) throw const SpotifyImportException('parse');
    Object? data;
    try {
      data = jsonDecode(m.group(1)!);
    } catch (_) {
      throw const SpotifyImportException('parse');
    }

    List<dynamic>? sections;
    try {
      final root = data as Map<dynamic, dynamic>;
      final first = (root['data'] as List).first as Map<dynamic, dynamic>;
      final page = first['data'] as Map<dynamic, dynamic>;
      sections = page['sections'] as List<dynamic>;
    } catch (_) {
      throw const SpotifyImportException('parse');
    }

    String? name;
    int? declaredCount;
    List<dynamic>? rawItems;

    for (final s in sections.whereType<Map<dynamic, dynamic>>()) {
      final sid = '${s['id']}';
      if (sid.contains('playlist-detail-header') &&
          s['items'] is List &&
          (s['items'] as List).isNotEmpty) {
        final header = (s['items'] as List).first as Map<dynamic, dynamic>;
        name = (header['title'] as String?)?.trim();
        final c = header['trackCount'];
        declaredCount = c is num && c > 0 ? c.round() : null;
      }
      if (s['itemKind'] == 'trackLockup') {
        rawItems = s['items'] as List?;
      }
    }

    final tracks = <SpotifyPlaylistTrack>[];
    for (final item in (rawItems ?? const []).whereType<Map<dynamic, dynamic>>()) {
      final title = (item['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;
      var artists = (item['artistName'] as String?)?.trim() ?? '';
      if (artists.isEmpty && item['subtitleLinks'] is List) {
        for (final link
            in (item['subtitleLinks'] as List).whereType<Map<dynamic, dynamic>>()) {
          final t = (link['title'] as String?)?.trim() ?? '';
          if (t.isNotEmpty) {
            artists = t;
            break;
          }
        }
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
      name: (name == null || name.isEmpty) ? 'Apple Music' : name,
      tracks: tracks,
      declaredTrackCount: declaredCount,
    );
  }

  final http.Client _client;
}
