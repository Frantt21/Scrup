import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img_pkg;

import '../core/track.dart';
import 'artwork_cache_service.dart';
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
  /// [force] ignora la caché de paleta (recalculo manual desde Ajustes).
  /// [artworkCache] si se provee, almacena/carga bytes de artwork en disco
  /// para evitar re-descargas de red.
  static Future<List<Color>> trioFor(
    String url,
    PaletteCacheStore store, {
    bool force = false,
    ArtworkCacheService? artworkCache,
  }) async {
    print('[SCRUP] trioFor: url=${url.substring(0, math.min(80, url.length))}… force=$force');
    if (!force) {
      final cached = store.getTrio(url);
      if (cached != null) {
        print('[SCRUP] trioFor: TRIO CACHE HIT → [${cached.map((c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}').join(', ')}]');
        return cached;
      }
      print('[SCRUP] trioFor: TRIO cache miss');
    } else {
      store.invalidate(url);
      print('[SCRUP] trioFor: FORCE invalidate + re-extract');
    }

    final bytes = await _fetchBytes(url, artworkCache: artworkCache);
    if (bytes == null) {
      print('[SCRUP] trioFor: NO BYTES fetched → empty');
      return const [];
    }
    print('[SCRUP] trioFor: got ${bytes.length} bytes → extracting trio');
    final trio = await trioFromBytes(url, bytes, store);
    print('[SCRUP] trioFor: RESULT → [${trio.map((c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}').join(', ')}]');
    final accent = store.get(url);
    print('[SCRUP] trioFor: ACCENT stored → #${accent?.toARGB32().toRadixString(16).padLeft(8, '0')}');
    return trio;
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
      print('[SCRUP] trioFromBytes: ${swatches.length} swatches extracted');
      if (swatches.isNotEmpty) {
        final domHsl = HSLColor.fromColor(swatches.first);
        print('[SCRUP] trioFromBytes: dominant=#${swatches.first.toARGB32().toRadixString(16).padLeft(8, '0')} sat=${domHsl.saturation.toStringAsFixed(3)} light=${domHsl.lightness.toStringAsFixed(3)}');
      }
      final trio = pickTrio(swatches);
      print('[SCRUP] trioFromBytes: pickTrio → [${trio.map((c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}').join(', ')}]');
      if (trio.isNotEmpty) {
        store.putTrio(url, trio);
        final accent = accentFromTrio(trio) ?? trio.first;
        print('[SCRUP] trioFromBytes: accentFromTrio → #${accent.toARGB32().toRadixString(16).padLeft(8, '0')} (dominantSat=${HSLColor.fromColor(trio.first).saturation.toStringAsFixed(3)})');
        store.put(url, accent);
      }
      return trio;
    } catch (e) {
      print('[SCRUP] trioFromBytes: ERROR $e');
      return const [];
    }
  }

  /// Decodifica [bytes] y cuantiza los píxeles — TODO el trabajo pesado
  /// (decode JPEG + resize + quantize) corre en UN solo isolate,
  /// eliminando `ui.instantiateImageCodec` del hilo de UI.
  static Future<List<Color>> extractSwatches(Uint8List bytes) async {
    return Isolate.run(() => _decodeAndQuantize(bytes));
  }

  /// Toda la pipeline pesada: decode → resize 96px → RGBA → quantize.
  /// Corre 100% fuera del hilo de UI.
  static List<Color> _decodeAndQuantize(Uint8List bytes) {
    final img = img_pkg.decodeImage(bytes);
    if (img == null) return const [];
    final resized = img_pkg.copyResize(img, width: 96, height: 96);
    final rgba = resized.getBytes(order: img_pkg.ChannelOrder.rgba);
    return _quantize(rgba);
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

  /// Bytes del artwork: disco local → caché → red con cadena de respaldo
  /// maxresdefault (1280px) → URL original.
  static Future<Uint8List?> _fetchBytes(
    String url, {
    ArtworkCacheService? artworkCache,
  }) async {
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

    // 1) Caché de artwork en disco: evita re-descargar portadas conocidas.
    if (artworkCache != null) {
      try {
        final cached = await artworkCache.load(url);
        if (cached != null && cached.length > 1024) {
          print('[SCRUP] _fetchBytes: ARTWORK DISK HIT (${cached.length} bytes)');
          return cached;
        }
        print('[SCRUP] _fetchBytes: artwork cache miss');
      } catch (_) {}
    }

    // 2) Red: cadena de respaldo maxresdefault → URL original.
    print('[SCRUP] _fetchBytes: fetching from network');
    for (final candidate in [Track.hiResThumbnail(url) ?? url, url]) {
      try {
        final resp = await http
            .get(Uri.parse(candidate), headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
          final bytes = resp.bodyBytes;
          print('[SCRUP] _fetchBytes: network OK ${bytes.length} bytes from ${candidate.length > 60 ? candidate.substring(0, 60) : candidate}…');
          // Persistir en disco para próximas sesiones.
          if (artworkCache != null) {
            try {
              await artworkCache.save(url, bytes);
              print('[SCRUP] _fetchBytes: saved to artwork disk cache');
            } catch (_) {}
          }
          return bytes;
        }
      } catch (_) {
        // Siguiente eslabón.
      }
    }
    print('[SCRUP] _fetchBytes: ALL network candidates FAILED');
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
    // El color DOMINANTE (más poblado por _quantize) define si la imagen
    // tiene color real. Antes se usaba maxSat de TODOS los bins, pero el
    // ruido JPEG (azul/morado en baja población) inflaba ese máximo y
    // hacía pasar portadas B/N como "con color" → acento azulado.
    final dominant = candidates.first;
    final domSat = HSLColor.fromColor(dominant).saturation;
    print('[SCRUP] pickTrio: dominant=#${dominant.toARGB32().toRadixString(16).padLeft(8, '0')} sat=${domSat.toStringAsFixed(3)}');
    if (domSat < kMinSaturation) {
      print('[SCRUP] pickTrio: MONOCHROME GUARD (sat $domSat < $kMinSaturation) → grays');
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

  /// Deriva el acento único (controles/lyrics) del trío: el color dominante
  /// (más poblado) define si hay color real; los secundarios con ruido JPEG
  /// no deben secuestrar el acento. En trío monocromo, plata neutra legible.
  static Color? accentFromTrio(List<Color> trio) {
    if (trio.isEmpty) return null;
    // Solo el dominante define: si tiene saturación real, hay color.
    if (HSLColor.fromColor(trio.first).saturation >= kMinSaturation) {
      return trio.first;
    }
    return HSLColor.fromColor(
      trio.first,
    ).withSaturation(0).withLightness(0.72).toColor();
  }
}
