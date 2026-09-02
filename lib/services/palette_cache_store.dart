import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';

/// In-memory + SQLite cache for artwork palette colors.
/// In-memory map is authoritative for reads (O(1) sync).
/// Only successful colors are persisted (failures can retry next session).
class PaletteCacheStore {
  PaletteCacheStore._(this._db);

  final AppDatabase _db;

  static const int _maxEntries = 1500;

  static const int _cacheVersion = 4;

  static const int _maxFailedEntries = 1000;

  // Key: url→int (accent) or url:t→list of 3 ints (trio).
  final Map<String, Object> _colors = {};

  static const String _trioPrefix = '\x00trio:';

  final Set<String> _dirty = {};

  // URLs that failed color extraction this session (shared across consumers).
  final Set<String> _failed = {};

  Timer? _saveDebounce;

  bool _saving = false;
  bool _savePending = false;

  // Loads from SQLite. Invalidates cache if version changed.
  static Future<PaletteCacheStore> load(AppDatabase db) async {
    final store = PaletteCacheStore._(db);

    // Version invalidation
    try {
      final versionRow = await db.allPalettes();
      final hasVersion = versionRow.any((r) => r.id == _versionKey);
      if (hasVersion) {
        final saved = versionRow.firstWhere((r) => r.id == _versionKey);
        if (saved.c1 != _cacheVersion) {
          await db.customStatement('DELETE FROM palette_cache');
            await db.upsertPalette(_versionKey, [_cacheVersion]);
        }
      } else {
        await db.customStatement('DELETE FROM palette_cache');
        await db.upsertPalette(_versionKey, [_cacheVersion]);
      }
    } catch (_) {}

    try {
      final rows = await db.allPalettes();
      for (final row in rows) {
        final id = row.id;
        if (id == _versionKey) continue; // metadata, no color
        if (row.c2 == null && row.c3 == null) {
          if (id.startsWith(_trioPrefix) || id.startsWith(_accentSuffix)) {
            store._colors[id] = row.c1 & 0xFFFFFFFF;
          } else {
            // Legacy accent: migrate to prefixed key.
            store._colors['$_accentSuffix$id'] = row.c1 & 0xFFFFFFFF;
          }
        } else {
          final key =
              (id.startsWith(_trioPrefix) || id.startsWith(_accentSuffix))
              ? id
              : '$_trioPrefix$id';
          store._colors[key] = [
            row.c1 & 0xFFFFFFFF,
            row.c2! & 0xFFFFFFFF,
            row.c3! & 0xFFFFFFFF,
          ];
        }
      }
    } catch (_) {
      store._colors.clear();
    }
    // Best-effort cleanup of legacy JSON cache.
    try {
      final base = await getApplicationSupportDirectory();
      final legacy = File(p.join(base.path, 'palette_cache.json'));
      if (await legacy.exists()) {
        await legacy.delete();
      }
    } catch (_) {}
    return store;
  }

  Color? get(String url) {
    final key = '$_accentSuffix$url';
    final argb = _colors[key];
    if (argb is! int) {
      return null;
    }
    return Color(argb);
  }

  List<Color>? getTrio(String url) {
    final key = '$_trioPrefix$url';
    final v = _colors[key];
    if (v is! List) {
      return null;
    }
    return [for (final argb in v) Color(argb as int)];
  }

  void put(String url, Color color) {
    final key = '$_accentSuffix$url';
    _colors[key] = color.toARGB32();
    _failed.remove(url);
    _scheduleSave(key);
  }

  void putTrio(String url, List<Color> trio) {
    assert(trio.length == 3);
    _colors['$_trioPrefix$url'] = [for (final c in trio) c.toARGB32()];
    _failed.remove(url);
    _scheduleSave('$_trioPrefix$url');
  }

  static const String _accentSuffix = '\x01accent:';

  static const String _versionKey = '\x02cache_version';

  // Marks URL as failed this session (shared across consumers).
  void markFailed(String url) {
    _failed.add(url);
    while (_failed.length > _maxFailedEntries) {
      _failed.remove(_failed.first);
    }
  }

  // Removes entry from memory + DB (for manual recalculation).
  Future<void> invalidate(String url) async {
    _colors.remove(url);
    _colors.remove('$_trioPrefix$url');
    _colors.remove('$_accentSuffix$url');
    _dirty.remove(url);
    _dirty.remove('$_trioPrefix$url');
    _dirty.remove('$_accentSuffix$url');
    try {
      await _db.deletePalette(url);
      await _db.deletePalette('$_trioPrefix$url');
      await _db.deletePalette('$_accentSuffix$url');
    } catch (_) {}
  }

  bool isFailed(String url) => _failed.contains(url);

  void _scheduleSave(String url) {
    _dirty.add(url);
    while (_colors.length > _maxEntries) {
      final oldest = _colors.keys.first;
      _colors.remove(oldest);
      _dirty.remove(oldest);
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_save());
    });
  }

  // Flush pending writes immediately (used on app close).
  Future<void> flush() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _save();
  }

  Future<void> _save() async {
    if (_dirty.isEmpty && !_saving) return;
    if (_saving) {
      _savePending = true;
      return;
    }
    _saving = true;
    try {
      for (final url in _dirty.toList()) {
        final v = _colors[url];
        if (v == null) continue;
        final colors = v is int ? [v] : List<int>.from(v as List);
        await _db.upsertPalette(url, colors);
      }
      _dirty.clear();
      await _db.trimPalettes(_maxEntries);
    } catch (_) {}
    _saving = false;
    if (_savePending) {
      _savePending = false;
      unawaited(_save());
    }
  }
}
