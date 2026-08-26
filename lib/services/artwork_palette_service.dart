import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';

import '../core/track.dart';
import 'palette_cache_store.dart';

/// Extracción de paletas de artwork — FUENTE ÚNICA para toda la app.
///
/// Un artwork produce exactamente UN trío de colores (background
/// fullscreen); el acento de controles/lyrics se DERIVA de ese trío (1 de
/// los 3). Así controles y fondo nunca discrepan y todo vive en la misma
/// caché SQLite ([PaletteCacheStore]).
///
/// GUARDIA MONOCROMA: en portadas ~90% negras/blancas los swatches que
/// sobreviven son RUIDO DE CROMA del JPEG (azulados/morados sin relación
/// con la imagen). Si NINGÚN swatch alcanza saturación real, el trío es una
/// rampa de GRISES oscuros sobre el negro base.
class ArtworkPaletteService {
  ArtworkPaletteService._();

  /// Saturación mínima (HSL) para considerar que un color es intención del
  /// artista y no ruido de compresión.
  static const double kMinSaturation = 0.20;

  static const String _userAgent = 'Scrup/0.1 (music player)';

  /// Devuelve el trío para [url], desde caché o extrayéndolo.
  ///
  /// [force] ignora la caché (recalculo manual desde Ajustes).
  static Future<List<Color>> trioFor(
    String url,
    PaletteCacheStore store, {
    bool force = false,
  }) async {
    if (!force) {
      final cached = store.getTrio(url);
      if (cached != null) return cached;
    } else {
      store.invalidate(url);
    }

    final bytes = await _fetchBytes(url);
    if (bytes == null) return const [];
    return trioFromBytes(url, bytes, store);
  }

  /// Extrae el trío desde bytes YA descargados (p. ej. los que el
  /// fullscreen muestra) y lo persiste con su acento derivado.
  ///
  /// TODO el trabajo pesado (decodificar + cuantizar) corre FUERA del
  /// isolate de UI: era la causa del tirón al cambiar de canción —
  /// PaletteGenerator decodificaba y cuantizaba imágenes de hasta 1280px
  /// en el hilo principal, dos veces por cambio (actual + precarga).
  static Future<List<Color>> trioFromBytes(
    String url,
    Uint8List bytes,
    PaletteCacheStore store,
  ) async {
    try {
      final swatches = await extractSwatches(bytes);
      final trio = pickTrio(swatches);
      if (trio.isNotEmpty) {
        store.putTrio(url, trio);
        // Derivar y persistir TAMBIÉN el acento único: los consumidores
        // antiguos (ThemeController) lo encuentran al instante y no vuelven
        // a descargar/analizar la portada por su cuenta.
        store.put(url, accentFromTrio(trio) ?? trio.first);
      }
      return trio;
    } catch (_) {
      return const [];
    }
  }

  /// Decodifica [bytes] REDUCIDO (96px vía engine, fuera del hilo UI) y
  /// cuantiza los píxeles en un isolate aparte → colores candidatos con
  /// población suficiente para el scoring del trío.
  static Future<List<Color>> extractSwatches(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 96,
      targetHeight: 96,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    frame.image.dispose();
    codec.dispose();
    if (data == null) return const [];
    final rgba = data.buffer.asUint8List();
    return Isolate.run(() => _quantize(rgba));
  }

  /// Cuantización simple por cubos RGB de 4 bits por canal: promedia el
  /// color de cada cubo y ordena por población. Sobre 96×96 son ~9k
  /// píxeles — microsegundos en el isolate.
  static List<Color> _quantize(Uint8List rgba) {
    final sumsR = <int, int>{};
    final sumsG = <int, int>{};
    final sumsB = <int, int>{};
    final counts = <int, int>{};

    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a < 255) continue; // transparencia: no aporta
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      // Clave 12 bits: r/g/b a 4 bits cada canal.
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      sumsR[key] = (sumsR[key] ?? 0) + r;
      sumsG[key] = (sumsG[key] ?? 0) + g;
      sumsB[key] = (sumsB[key] ?? 0) + b;
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in entries.take(16))
        Color.fromARGB(
          255,
          sumsR[e.key]! ~/ e.value,
          sumsG[e.key]! ~/ e.value,
          sumsB[e.key]! ~/ e.value,
        ),
    ];
  }

  /// Bytes del artwork: archivo local (portadas propias) o red con cadena
  /// de respaldo maxresdefault (1280px) → URL original.
  static Future<Uint8List?> _fetchBytes(String url) async {
    final lower = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      try {
        final f = File(url);
        if (await f.exists()) {
          final b = await f.readAsBytes();
          if (b.length > 128) return b;
        }
      } catch (_) {}
      return null;
    }
    for (final candidate in [Track.hiResThumbnail(url) ?? url, url]) {
      try {
        final resp = await http
            .get(Uri.parse(candidate), headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 10));
        // >1KB: descarta placeholders grises de YouTube (404 disfrazado).
        if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
          return resp.bodyBytes;
        }
      } catch (_) {
        // Siguiente eslabón.
      }
    }
    return null;
  }

  /// Elige el trío de una lista de colores candidatos (ordenados por
  /// población): top-3 por saturación×contraste con separación mínima de
  /// tono. Con guardia monocroma (ver clase).
  static List<Color> pickTrio(List<Color> candidates) {
    double score(Color c) {
      final hsl = HSLColor.fromColor(c);
      return hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 2);
    }

    final swatches = [...candidates]
      ..sort((a, b) => score(b).compareTo(score(a)));
    if (swatches.isEmpty) return const [];

    // ── Guardia monocroma ────────────────────────────────────────────────
    // El MÁXIMO de saturación de toda la paleta define si hay color real.
    // Evita que el ruido azul/morado de JPEGs B/N o casi negros tiña el
    // fondo fullscreen.
    final maxSat = swatches.fold<double>(
      0,
      (acc, c) => math.max(acc, HSLColor.fromColor(c).saturation),
    );
    if (maxSat < kMinSaturation) {
      // Rampa de grises OSCUROS sobre el negro base (lyrics siempre
      // legibles), independiente de la luminancia dominante.
      return const [Color(0xFF5A5A5A), Color(0xFF3C3C3C), Color(0xFF242424)];
    }

    double hueOf(Color c) => HSLColor.fromColor(c).hue;
    bool sat(Color c) => HSLColor.fromColor(c).saturation >= 0.15;

    final picked = <Color>[swatches.first];
    for (final c in swatches.skip(1)) {
      if (picked.length >= 3) break;
      // Distancia de tono SOLO entre colores con saturación real.
      final farEnough = picked.every((p) {
        if (!sat(p) || !sat(c)) return true;
        final d = (hueOf(p) - hueOf(c)).abs() % 360;
        return math.min(d, 360 - d) >= 25;
      });
      if (farEnough) picked.add(c);
    }
    // Relleno por luminancia si faltaron matices distintos (monocromos
    // parciales): variaciones del primero, sin inventar hue ajenos.
    while (picked.length < 3) {
      final base = HSLColor.fromColor(picked.first);
      final shift = picked.length == 1 ? 0.22 : -0.18;
      picked.add(
        base
            .withLightness((base.lightness + shift).clamp(0.08, 0.85))
            .toColor(),
      );
    }
    return picked;
  }

  /// Deriva el acento único (controles/lyrics) del trío: el primer color
  /// con saturación real; en trío monocromo, plata neutra legible.
  static Color? accentFromTrio(List<Color> trio) {
    if (trio.isEmpty) return null;
    for (final c in trio) {
      if (HSLColor.fromColor(c).saturation >= kMinSaturation) return c;
    }
    final hsl = HSLColor.fromColor(trio.first);
    return hsl.withSaturation(0).withLightness(0.72).toColor();
  }
}
