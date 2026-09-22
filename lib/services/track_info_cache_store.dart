import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytmusic_service.dart';

/// Persistent per-track cache for the now-playing panel:
/// - `channels/<videoId>.json` — resolved artist channel (the owner of a
///   track NEVER changes).
/// - `credits/<videoId>.json` — official song credits (fixed at release).
/// One small JSON per track, no TTL by design; entries are version-stamped
/// and dropped when the format changes.
class TrackInfoCacheStore {
  TrackInfoCacheStore({this.directoryOverride});

  static const int version = 1;

  final Directory? directoryOverride;

  final Map<String, (String, String)> _channels = {};
  final Map<String, YtmTrackCredits> _credits = {};
  final Set<String> _missing = {};
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final override = directoryOverride;
    if (override != null) return override;
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'track_info_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Resolved channel for a track, or null when nothing is cached.
  Future<(String, String)?> readChannel(String videoId) async {
    final hit = _channels[videoId];
    if (hit != null) return hit;
    if (_missing.contains('c:$videoId')) return null;
    final data = await _read('channels', videoId);
    if (data == null) {
      _missing.add('c:$videoId');
      return null;
    }
    final id = data['id'];
    if (id is! String || id.isEmpty) return null;
    final entry = (id, data['name'] is String ? data['name'] as String : '');
    _channels[videoId] = entry;
    return entry;
  }

  void writeChannel(String videoId, String browseId, String name) {
    if (videoId.isEmpty || browseId.isEmpty) return;
    _channels[videoId] = (browseId, name);
    _missing.remove('c:$videoId');
    unawaited(_write('channels', videoId, {
      'v': version,
      'id': browseId,
      'name': name,
    }));
  }

  /// Cached credits for a track, or null when nothing is cached.
  Future<YtmTrackCredits?> readCredits(String videoId) async {
    final hit = _credits[videoId];
    if (hit != null) return hit;
    if (_missing.contains('k:$videoId')) return null;
    final data = await _read('credits', videoId);
    if (data == null) {
      _missing.add('k:$videoId');
      return null;
    }
    final credits = _creditsFromJson(data);
    if (credits == null || credits.isEmpty) return null;
    _credits[videoId] = credits;
    return credits;
  }

  void writeCredits(String videoId, YtmTrackCredits credits) {
    if (videoId.isEmpty || credits.isEmpty) return;
    _credits[videoId] = credits;
    _missing.remove('k:$videoId');
    unawaited(_write('credits', videoId, {
      'v': version,
      ..._creditsToJson(credits),
    }));
  }

  Future<Map<String, dynamic>?> _read(String sub, String videoId) async {
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, sub, '$videoId.json'));
      if (!await f.exists()) return null;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map<String, dynamic> || data['v'] != version) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
    String sub,
    String videoId,
    Map<String, dynamic> data,
  ) async {
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, sub, '$videoId.json'));
      await f.create(recursive: true);
      await f.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _channels.clear();
    _credits.clear();
    _missing.clear();
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ── Credits (de)serialization ────────────────────────────────────────

  static Map<String, dynamic> _creditsToJson(YtmTrackCredits c) => {
        'sections': [
          for (final s in c.sections)
            {
              'role': s.role,
              'names': s.names,
            },
        ],
        if (c.album != null) 'album': c.album,
        if (c.distributor != null) 'distributor': c.distributor,
      };

  static YtmTrackCredits? _creditsFromJson(Map<String, dynamic> j) {
    final raw = j['sections'];
    if (raw is! List) return null;
    final sections = <YtmCreditSection>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final role = e['role'];
      final names = e['names'];
      if (role is! String || role.isEmpty || names is! List) continue;
      sections.add(
        YtmCreditSection(
          role: role,
          names: [for (final n in names) if (n is String) n],
        ),
      );
    }
    return YtmTrackCredits(
      sections: sections,
      album: j['album'] is String ? j['album'] as String : null,
      distributor:
          j['distributor'] is String ? j['distributor'] as String : null,
    );
  }
}
