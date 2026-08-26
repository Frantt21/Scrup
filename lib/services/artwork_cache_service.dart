import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_cache_service.dart' show CacheStats;

/// Caché de bytes de artwork en disco.
///
/// Cada portada se almacena como un archivo cuyo nombre es el hash SHA-256
/// de la URL, evitando problemas con caracteres especiales en rutas. El
/// caché está acotado por tamaño con recorte LRU por mtime, igual que
/// [AudioCacheService].
///
/// El objetivo es evitar re-descargar portadas de red en cada cambio de
/// canción o reinicio de sesión: los bytes ya están en disco y se leen en
/// microsegundos.
class ArtworkCacheService {
  ArtworkCacheService({int? maxSizeBytes})
    : maxSizeBytes = maxSizeBytes ?? _defaultMaxSize;

  /// Límite por defecto: 500 MiB (suficiente para miles de portadas
  /// típicas de 100–300 KB cada una).
  static const int _defaultMaxSize = 500 * 1024 * 1024;

  final int maxSizeBytes;

  Directory? _dir;

  /// Directorio raíz del caché (creándolo si no existe).
  Future<Directory> cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'artwork_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Nombre de archivo para una URL: SHA-256 hex (sin extensión; todas las
  /// portadas son JPEG/PNG indistinguibles en este contexto).
  static String _hashName(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  /// Ruta del archivo en disco para [url] (sin leer bytes).
  /// Devuelve `null` si no existe en caché.
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

  /// Intenta leer los bytes de artwork desde el disco. Devuelve `null` si
  /// no están cacheados. Actualiza el mtime para el LRU.
  Future<Uint8List?> load(String url) async {
    final dir = await cacheDir();
    final file = File(p.join(dir.path, _hashName(url)));
    try {
      if (!await file.exists()) return null;
      // Touch LRU.
      await file.setLastModified(DateTime.now());
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Guarda bytes de artwork en disco. Silencioso: si falla el disco, se
  /// ignora (la app sigue funcionando con red).
  Future<void> save(String url, Uint8List bytes) async {
    try {
      final dir = await cacheDir();
      final file = File(p.join(dir.path, _hashName(url)));
      await file.writeAsBytes(bytes, flush: true);
      await _enforceLimit(dir);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Elimina archivos desde el más antiguo hasta quedar bajo el límite.
  /// Corre en un isolate para no bloquear el hilo de UI con un caché grande.
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

  /// Borra todo el caché de artwork.
  Future<void> clear() async {
    final dir = await cacheDir();
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }

  /// Resumen del caché.
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
