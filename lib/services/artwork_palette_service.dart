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

/// Extracts artwork palettes — single source for the whole app.
/// Monochrome guard: if no swatch has real saturation, returns greys.
class ArtworkPaletteService {
  ArtworkPaletteService._();

  static const double kMinSaturation = 0.30;

  static const double kDarknessThreshold = 0.10;

  static const String _userAgent = 'Scrup/0.1 (music player)';

  // Returns trio for URL from cache or extracted. [force] skips cache.
  static Future<List<Color>> trioFor(
    String url,
    PaletteCacheStore store, {
    bool force = false,
    ArtworkCacheService? artworkCache,
  }) async {
    if (!force) {
      final cached = store.getTrio(url);
      if (cached != null) {
        return cached;
      }
    } else {
      store.invalidate(url);
    }

    final bytes = await _fetchBytes(url, artworkCache: artworkCache);
    if (bytes == null) {
      return const [];
    }
    final trio = await trioFromBytes(url, bytes, store);
    return trio;
  }

  // Extracts trio from already-downloaded bytes. Heavy work runs off UI.
  // The ACCENT is shared with the cheap path: BOTH paths derive it with
  // accentFromSwatches over the same swatches, so the player and any trio
  // consumer always agree for the same artwork.
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
        final accent = accentFromSwatches(swatches) ?? trio.first;
        store.put(url, accent);
      }
      return trio;
    } catch (_) {
      return const [];
    }
  }

  // ── Single accent (cheap) ──────────────────────────────────────────────
  // For surfaces that paint their background with the accent (player,
  // miniplayer, lyrics): ONE color from the artwork, no trios or full palettes.
  // Cached by URL like the rest.

  /// Acento para [url]: del caché o extrayéndolo ahora (bytes → un color).
  /// Devuelve `null` si no hay bytes o la extracción falla.
  static Future<Color?> accentFor(
    String url,
    PaletteCacheStore store, {
    bool force = false,
    ArtworkCacheService? artworkCache,
  }) async {
    if (!force) {
      final cached = store.get(url);
      if (cached != null) return cached;
    } else {
      store.invalidate(url);
    }
    final bytes = await _fetchBytes(url, artworkCache: artworkCache);
    if (bytes == null) return null;
    return accentFromBytes(url, bytes, store);
  }

  /// Extrae el acento único de unos bytes ya descargados (decode en
  /// isolate) y lo guarda en el caché.
  static Future<Color?> accentFromBytes(
    String url,
    Uint8List bytes,
    PaletteCacheStore store,
  ) async {
    try {
      final swatches = await extractSwatches(bytes);
      final accent = accentFromSwatches(swatches);
      if (accent != null) store.put(url, accent);
      return accent;
    } catch (_) {
      return null;
    }
  }

  /// Chroma of a color: saturation weighted by "distance from mid-grey".
  /// A near-white cube (#faf1f2, S≈0.45) or a near-black one (#0a1716,
  /// S≈0.39) BOTH carry almost no visible color — pure HSL saturation lies
  /// for accents; chroma does not.
  static double chromaOf(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.saturation * (1 - (2 * hsl.lightness - 1).abs());
  }

  /// Un solo color: el cubo con MAYOR CROMA visible (no el primero con
  /// saturación — eso elegía blancos rotos o negros teñidos), con desempate
  /// por población y umbrales mínimos de saturación y croma. Si ningún
  /// cubo es realmente colorido (artwork B/N), plata neutra del dominante.
  static Color? accentFromSwatches(List<Color?> swatches) {
    final candidates = swatches.whereType<Color>().toList();
    if (candidates.isEmpty) return null;
    Color? best;
    var bestChroma = 0.0;
    var bestPop = -1;
    for (final c in candidates) {
      final hsl = HSLColor.fromColor(c);
      if (hsl.saturation < kMonoSaturationThreshold) continue;
      final chroma = chromaOf(c);
      if (chroma < kMinVisibleChroma) continue;
      if (chroma > bestChroma ||
          (chroma == bestChroma && bestPop < 0)) {
        best = c;
        bestChroma = chroma;
        bestPop = candidates.indexOf(c);
      }
    }
    if (best != null) return best;
    return neutralSilver(
      candidates.first,
      minLightness: 0.60,
      maxLightness: 0.82,
    );
  }

  /// Minimum visible chroma for a cube to count as a color (near-white and
  /// near-black tinted cubes fall below this).
  static const double kMinVisibleChroma = 0.10;

  static const double kMonoSaturationThreshold = 0.22;

  static Color neutralSilver(
    Color src, {
    required double minLightness,
    required double maxLightness,
  }) {
    final hsl = HSLColor.fromColor(src);
    return hsl
        .withSaturation(0)
        .withLightness(hsl.lightness.clamp(minLightness, maxLightness))
        .toColor();
  }

  // Decode and quantize pixels in a background isolate.
  static Future<List<Color>> extractSwatches(Uint8List bytes) async {
    return Isolate.run(() => _decodeAndQuantize(bytes));
  }

  static List<Color> _decodeAndQuantize(Uint8List bytes) {
    final img = img_pkg.decodeImage(bytes);
    if (img == null) return const [];
    final resized = img_pkg.copyResize(img, width: 96, height: 96);
    final rgba = resized.getBytes(order: img_pkg.ChannelOrder.rgba);
    return _quantize(rgba);
  }

  // Simple quantization: average color per 4-bit RGB cube, sorted by count.
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

  // Fetch artwork bytes: disk -> cache -> network with hi-res fallback.
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

    // Disk cache: avoids re-downloading known covers.
    if (artworkCache != null) {
      try {
        final cached = await artworkCache.load(url);
        if (cached != null && cached.length > 1024) {
          return cached;
        }
      } catch (_) {}
    }

    // Network: canonical square crop first (SAME framing as the small
    // variants — dropping the "-p" crop yields a DIFFERENT image), then
    // plain hi-res, then the original URL.
    final square = Track.squareHiResThumbnail(url);
    final candidates = <String>[
      if (square != null && square != url) square,
      Track.hiResThumbnail(url) ?? url,
      url,
    ];
    for (final candidate in candidates) {
      try {
        final resp = await http
            .get(Uri.parse(candidate), headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
          final bytes = resp.bodyBytes;
          if (artworkCache != null) {
            try {
              await artworkCache.save(url, bytes);
            } catch (_) {}
          }
          return bytes;
        }
      } catch (_) {
        // Siguiente eslabón.
      }
    }
    return null;
  }

  // Picks top-3 by visible chroma with min hue separation.
  static List<Color> pickTrio(List<Color> candidates) {
    double score(Color c) => chromaOf(c);

    final swatches = [...candidates]
      ..sort((a, b) => score(b).compareTo(score(a)));
    if (swatches.isEmpty) return const [];

    // Monochrome guard: check top-5 by population for real saturation.
    bool isMonochrome = true;
    for (final s in candidates.take(5)) {
      final hsl = HSLColor.fromColor(s);
      if (hsl.saturation >= kMinSaturation &&
          hsl.lightness >= kDarknessThreshold) {
        isMonochrome = false;
        break;
      }
    }
    if (isMonochrome) {
      return const [Color(0xFF5A5A5A), Color(0xFF3C3C3C), Color(0xFF242424)];
    }

    double hueOf(Color c) => HSLColor.fromColor(c).hue;
    bool sat(Color c) => HSLColor.fromColor(c).saturation >= 0.15;

    // Real colors (saturation + lightness) go first.
    bool realColor(Color c) {
      final hsl = HSLColor.fromColor(c);
      return hsl.saturation >= kMinSaturation &&
          hsl.lightness >= kDarknessThreshold;
    }

    final ordered = [
      ...swatches.where(realColor),
      ...swatches.where((c) => !realColor(c)),
    ];

    final picked = <Color>[ordered.first];
    for (final c in ordered.skip(1)) {
      if (picked.length >= 3) break;
      final farEnough = picked.every((p) {
        if (!sat(p) || !sat(c)) return true;
        final d = (hueOf(p) - hueOf(c)).abs() % 360;
        return math.min(d, 360 - d) >= 25;
      });
      if (farEnough) picked.add(c);
    }
    // Fill remaining slots with lightness variations of the first color.
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

  // Derives accent (controls/lyrics) from trio. Tries EVERY member with the
  // same chroma rule as accentFromSwatches (not just trio.first): the top
  // chroma cube may sit in any slot after hue separation. Silver fallback
  // keeps parity with the canonical accent for borderline covers.
  static Color? accentFromTrio(List<Color> trio) {
    if (trio.isEmpty) return null;
    for (final c in trio) {
      final hsl = HSLColor.fromColor(c);
      if (hsl.saturation >= kMonoSaturationThreshold &&
          chromaOf(c) >= kMinVisibleChroma) {
        return c;
      }
    }
    final hsl = HSLColor.fromColor(trio.first);
    return hsl.withSaturation(0).withLightness(0.72).toColor();
  }

  /// True when BLACK ink is readable on [background]. Uses the WCAG
  /// relative-luminance threshold (0.179), NOT 0.5: the luminance scale is
  /// gamma-encoded, so perceptual light greys (e.g. #B5B5B5 ≈ 0.46) fall
  /// well below 0.5 and were wrongly rendered with white ink.
  static bool prefersBlackInk(Color background) {
    final hsl = HSLColor.fromColor(background);
    if (hsl.lightness >= 0.73) return true;
    return background.computeLuminance() >= 0.179;
  }
}
