import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_cache_service.dart' show CacheStats;

/// On-disk artwork byte cache with LRU eviction. Names are SHA-256 hashes.
class ArtworkCacheService {
  ArtworkCacheService({int? maxSizeBytes})
    : maxSizeBytes = maxSizeBytes ?? _defaultMaxSize;

  static const int _defaultMaxSize = 500 * 1024 * 1024;

  final int maxSizeBytes;

  Directory? _dir;

  Future<Directory> cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'artwork_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  static String _hashName(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  // Returns file path on disk (touching LRU) or null.
  Future<String?> filePathFor(String url) async {
    final dir = await cacheDir();
    final file = File(p.join(dir.path, _hashName(url)));
    try {
      if (!await file.exists()) return null;
      await file.setLastModified(DateTime.now());
      return file.path;
    } catch (_) {
      return null;
    }
  }

  // Reads cached artwork bytes from disk, touching LRU.
  Future<Uint8List?> load(String url) async {
    final dir = await cacheDir();
    final file = File(p.join(dir.path, _hashName(url)));
    try {
      if (!await file.exists()) return null;
      await file.setLastModified(DateTime.now());
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String url, Uint8List bytes) async {
    try {
      final dir = await cacheDir();
      final file = File(p.join(dir.path, _hashName(url)));
      await file.writeAsBytes(bytes, flush: true);
      await _enforceLimit(dir);
    } catch (_) {}
  }

  // Evicts oldest files (LRU) until under size limit. Runs in isolate.
  Future<void> _enforceLimit(Directory dir) async {
    final dirPath = dir.path;
    final limit = maxSizeBytes;
    await Isolate.run(() {
      final d = Directory(dirPath);
      if (!d.existsSync()) return;
      final files = d.listSync().whereType<File>().toList();
      var total = 0;
      for (final f in files) {
        total += f.statSync().size;
      }
      if (total <= limit) return;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      for (final f in files) {
        if (total <= limit) return;
        final size = f.statSync().size;
        f.deleteSync();
        total -= size;
      }
    });
  }

  Future<void> clear() async {
    final dir = await cacheDir();
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }

  Future<ArtworkCacheStats> stats() async {
    final dir = await cacheDir();
    final dirPath = dir.path;
    return Isolate.run(() {
      var count = 0;
      var bytes = 0;
      final d = Directory(dirPath);
      if (d.existsSync()) {
        for (final e in d.listSync()) {
          if (e is File) {
            count++;
            try {
              bytes += e.statSync().size;
            } catch (_) {}
          }
        }
      }
      return ArtworkCacheStats(fileCount: count, bytes: bytes);
    });
  }
}

class ArtworkCacheStats extends CacheStats {
  const ArtworkCacheStats({required super.fileCount, required super.bytes});
}
