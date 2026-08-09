import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Caché de colores extraídos de artworks en disco (JSON en el directorio de
/// soporte de la app): evita re-descargar miniaturas para volver a extraer
/// la paleta entre sesiones (portadas de playlist, portadas de canciones y
/// el acento del reproductor).
///
/// - Solo persiste colores EXITOSOS: un fallo de extracción no se guarda,
///   así la próxima sesión puede reintentarlo (p. ej. si el artwork apareció).
/// - Escritura con debounce: las ráfagas de extracción (scroll en una
///   playlist) no machacan el disco; se escribe una sola vez al terminar.
/// - Escritura atómica (temp + rename): nunca deja un JSON a medias.
/// - Acotado a [_maxEntries] colores (LRU simple por orden de inserción).
class PaletteCacheStore {
  PaletteCacheStore._();

  /// Límite de entradas para que el archivo no crezca sin control.
  static const int _maxEntries = 1500;

  /// Límite de URLs fallidas recordadas en la sesión (mismas razones que
  /// [_maxEntries]: no dejar que el set crezca sin control).
  static const int _maxFailedEntries = 1000;

  /// URL de artwork → color ARGB (int). LinkedHashMap: orden de inserción.
  final Map<String, int> _colors = {};

  /// URLs que fallaron al extraer el color EN ESTA SESIÓN: compartidas entre
  /// todos los consumidores (playlist, reproductor) para que nadie vuelva a
  /// descargar una miniatura que otro ya intentó. No se persisten: los fallos
  /// se reintentan en la próxima sesión (por si el artwork apareció).
  final Set<String> _failed = {};

  File? _file;
  Timer? _saveDebounce;

  /// Guarda en vuelo + datos pendientes: serializa las escrituras para que
  /// dos `_save()` (p. ej. debounce y flush al cerrar) no pisen el mismo
  /// `.tmp` a la vez (en Windows fallaría por sharing violation).
  bool _saving = false;
  bool _savePending = false;

  /// Lee el archivo de disco y devuelve el caché. Best-effort: si el archivo
  /// no existe o está corrupto, arranca vacío sin romper nada.
  static Future<PaletteCacheStore> load() async {
    final store = PaletteCacheStore._();
    try {
      final base = await getApplicationSupportDirectory();
      store._file = File(p.join(base.path, 'palette_cache.json'));
      if (await store._file!.exists()) {
        final raw = await store._file!.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final value = int.tryParse(entry.value.toString());
            if (value != null) {
              // Enmascarar a 32 bits: un archivo corrupto/ajeno con un valor
              // fuera de rango rompería `Color(argb)` (assert en debug).
              store._colors[entry.key] = value & 0xFFFFFFFF;
            }
          }
        }
      }
    } catch (_) {
      // Archivo ausente/corrupto: arrancar vacío.
    }
    return store;
  }

  /// Color cacheado para una URL, o null si nunca se extrajo con éxito.
  Color? get(String url) {
    final argb = _colors[url];
    return argb == null ? null : Color(argb);
  }

  /// Guarda el color extraído de una URL (solo valores no nulos: un fallo
  /// no se persiste para poder reintentarlo en la próxima sesión).
  void put(String url, Color color) {
    _colors[url] = color.toARGB32();
    _failed.remove(url);
    _trim();
    _scheduleSave();
  }

  /// Marca una URL como fallida en esta sesión: los demás consumidores la
  /// verán vía [isFailed] y no volverán a descargarla.
  void markFailed(String url) {
    _failed.add(url);
    while (_failed.length > _maxFailedEntries) {
      _failed.remove(_failed.first);
    }
  }

  /// `true` si la URL ya se intentó extraer y falló en esta sesión (por este
  /// u otro consumidor).
  bool isFailed(String url) => _failed.contains(url);

  /// Recorta al máximo de entradas quitando las más antiguas.
  void _trim() {
    while (_colors.length > _maxEntries) {
      _colors.remove(_colors.keys.first);
    }
  }

  void _scheduleSave() {
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
    if (_saving) {
      // Una escritura está en vuelo: marcar pendiente y volver a guardar al
      // terminar (así nunca se pierde lo que se añadió mientras se escribía).
      _savePending = true;
      return;
    }
    _saving = true;
    try {
      final file = _file;
      if (file != null) {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(_colors), flush: true);
        await tmp.rename(file.path);
      }
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
