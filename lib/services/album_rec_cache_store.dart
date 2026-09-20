import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistent cache of library album recommendations (seed key → albums).
///
/// - One JSON file (`albums.json`) loaded once per session; writes are
///   deferred (debounce 1s).
/// - Values never expire: the seed set IS the key, so playlist changes
///   produce a new key that recomputes while stale entries just sit idle
///   (small, capped by library size).
class AlbumRecCacheStore {
  AlbumRecCacheStore({this.directoryOverride});

  final Directory? directoryOverride;

  final Map<String, List<Map<String, String>>> _mem = {};
  bool _loaded = false;
  Timer? _flushTimer;
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final override = directoryOverride;
    if (override != null) return override;
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'search_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Loads the map from disk (once per session). Read failures never break
  /// the app: the map stays empty and repopulates in background.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, 'albums.json'));
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map<String, dynamic>) return;
      for (final e in data.entries) {
        final v = e.value;
        if (e.key.isEmpty || v is! List) continue;
        final albums = <Map<String, String>>[];
        for (final item in v) {
          if (item is! Map<String, dynamic>) continue;
          final id = item['id'];
          final title = item['title'];
          if (id is! String || id.isEmpty || title is! String) continue;
          albums.add({
            'id': id,
            'title': title,
            'thumb': item['thumb'] is String ? item['thumb'] as String : '',
            'year': item['year'] is String ? item['year'] as String : '',
          });
        }
        if (albums.isNotEmpty) _mem[e.key] = albums;
      }
    } catch (_) {}
  }

  /// Cached album list for [key] (disk on first read), or null.
  Future<List<Map<String, String>>?> get(String key) async {
    await _ensureLoaded();
    return _mem[key];
  }

  /// Stores the list (memory + deferred persistence). Empty lists are not
  /// cached: a network failure must not stick for the whole app lifetime.
  Future<void> put(String key, List<Map<String, String>> albums) async {
    if (key.isEmpty || albums.isEmpty) return;
    _mem.remove(key);
    _mem[key] = albums;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    try {
      final dir = await _cacheDir();
      final f = File(p.join(dir.path, 'albums.json'));
      await f.writeAsString(jsonEncode(_mem), flush: true);
    } catch (_) {}
  }
}
