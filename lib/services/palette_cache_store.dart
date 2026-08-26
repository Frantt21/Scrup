import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';

/// Caché de paletas de artwork: acento del reproductor (1 color) y trío del
/// fondo fullscreen (3 colores), por URL de portada.
///
/// PERSISTENCIA EN SQLITE (tabla palette_cache, migrado desde JSON): escrituras
/// incrementales por entrada, sin reescritura completa del archivo ni carga
/// total que crezca sin límite. El recorte LRU lo hace SQL.
///
/// ARQUITECTURA: el mapa en memoria es AUTORITATIVO para las lecturas
/// (get/getTrio son SÍNCRONOS y O(1)); la base es solo el almacén duradero.
/// Las escrituras van al mapa al instante y a la DB con debounce (las ráfagas
/// de extracción, p. ej. scroll en una playlist, terminan en UNA tanda).
///
/// - Solo persiste colores EXITOSOS: un fallo no se guarda, así la próxima
///   sesión puede reintentarlo (p. ej. si el artwork apareció).
/// - Acotado a [_maxEntries] colores (recorte LRU por usedAt en SQL).
class PaletteCacheStore {
  PaletteCacheStore._(this._db);

  final AppDatabase _db;

  /// Límite de entradas (el recorte real lo hace trimPalettes en SQL).
  static const int _maxEntries = 1500;

  /// Límite de URLs fallidas recordadas en la sesión.
  static const int _maxFailedEntries = 1000;

  /// URL → int ARGB (acento) o lista de 3 ARGB (trío).
  final Map<String, Object> _colors = {};

  /// Entradas nuevas/cambiadas pendientes de volcar a la DB.
  final Set<String> _dirty = {};

  /// URLs que fallaron al extraer el color EN ESTA SESIÓN: compartidas entre
  /// todos los consumidores (playlist, reproductor) para que nadie vuelva a
  /// descargar una miniatura que otro ya intentó. No se persisten: los fallos
  /// se reintentan en la próxima sesión (por si el artwork apareció).
  final Set<String> _failed = {};

  Timer? _saveDebounce;

  bool _saving = false;
  bool _savePending = false;

  /// Carga las entradas desde SQLite. Best-effort: si la DB falla, arranca
  /// vacío sin romper nada. Elimina el JSON legacy si aún existe (migración
  /// ya cubierta por la tabla).
  static Future<PaletteCacheStore> load(AppDatabase db) async {
    final store = PaletteCacheStore._(db);
    try {
      final rows = await db.allPalettes();
      for (final row in rows) {
        if (row.c2 == null || row.c3 == null) {
          store._colors[row.id] = row.c1 & 0xFFFFFFFF;
        } else {
          // Enmascarar a 32 bits: un dato corrupto rompería Color(argb).
          store._colors[row.id] = [
            row.c1 & 0xFFFFFFFF,
            row.c2! & 0xFFFFFFFF,
            row.c3! & 0xFFFFFFFF,
          ];
        }
      }
    } catch (_) {
      store._colors.clear();
    }
    // Limpieza best-effort del caché JSON anterior.
    try {
      final base = await getApplicationSupportDirectory();
      final legacy = File(p.join(base.path, 'palette_cache.json'));
      if (await legacy.exists()) {
        await legacy.delete();
      }
    } catch (_) {
      // Si no se puede borrar, queda inofensivo en disco.
    }
    return store;
  }

  /// Color cacheado para una URL, o null si nunca se extrajo con éxito.
  Color? get(String url) {
    final argb = _colors[url];
    if (argb is! int) return null;
    return Color(argb);
  }

  /// Trío de colores cacheado para una URL (fondo fullscreen), o null.
  List<Color>? getTrio(String url) {
    final v = _colors[url];
    if (v is! List) return null;
    return [for (final argb in v) Color(argb as int)];
  }

  /// Guarda el color extraído de una URL (solo valores no nulos: un fallo
  /// no se persiste para poder reintentarlo en la próxima sesión).
  void put(String url, Color color) {
    _colors[url] = color.toARGB32();
    _failed.remove(url);
    _scheduleSave(url);
  }

  /// Guarda el trío extraído de una URL.
  void putTrio(String url, List<Color> trio) {
    assert(trio.length == 3);
    _colors[url] = [for (final c in trio) c.toARGB32()];
    _failed.remove(url);
    _scheduleSave(url);
  }

  /// Marca una URL como fallida en esta sesión: los demás consumidores la
  /// verán vía [isFailed] y no volverán a descargarla.
  void markFailed(String url) {
    _failed.add(url);
    while (_failed.length > _maxFailedEntries) {
      _failed.remove(_failed.first);
    }
  }

  /// Elimina una entrada (memoria + DB): para recálculos manuales.
  Future<void> invalidate(String url) async {
    _colors.remove(url);
    _dirty.remove(url);
    try {
      await _db.deletePalette(url);
    } catch (_) {}
  }

  /// `true` si la URL ya se intentó extraer y falló en esta sesión (por este
  /// u otro consumidor).
  bool isFailed(String url) => _failed.contains(url);

  void _scheduleSave(String url) {
    _dirty.add(url);
    while (_colors.length > _maxEntries) {
      // El recorte REAL es SQL (LRU por used_at); esto solo acota memoria.
      final oldest = _colors.keys.first;
      _colors.remove(oldest);
      _dirty.remove(oldest);
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_save());
    });
  }

  /// Persiste de forma inmediata (cancela el debounce pendiente). Se usa al
  /// cerrar la app para no perder los últimos colores extraídos.
  Future<void> flush() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _save();
  }

  Future<void> _save() async {
    if (_dirty.isEmpty && !_saving) return;
    if (_saving) {
      // Una escritura está en vuelo: marcar pendiente y volver a guardar al
      // terminar (así nunca se pierde lo añadido mientras se escribía).
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
    } catch (_) {
      // Best-effort: el caché en memoria sigue sirviendo en esta sesión.
    }
    _saving = false;
    if (_savePending) {
      _savePending = false;
      unawaited(_save());
    }
  }
}
