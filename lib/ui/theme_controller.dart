import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';

import '../core/track.dart';
import '../services/artwork_cache_service.dart';
import '../services/artwork_palette_service.dart';
import '../services/palette_cache_store.dart';
import '../services/player_service.dart';

/// Lila por defecto cuando no hay pista o el artwork no carga.
const Color kDefaultAccent = Color(0xFFC084FC);

/// Deriva el color de acento de la app a partir del artwork de la pista
/// actual. Escucha el reproductor y, al cambiar de pista, descarga la
/// portada, extrae su paleta y expone el color más llamativo.
///
/// Es *best-effort*: si no hay portada o falla la descarga/análisis, se
/// mantiene el acento por defecto (lila) sin romper nada.
class ThemeController extends ChangeNotifier {
  ThemeController(
    this._player, {
    this.paletteCache,
    this.artworkCache,
  }) {
    // Leer la pista ya publicada (p. ej. sesión restaurada): los streams
    // broadcast no re-emiten lo pasado, así que el acento se aplica aquí.
    _onTrackChanged(_player.currentTrackValue);
    _sub = _player.currentTrack.listen(_onTrackChanged);
  }

  final PlayerService _player;

  /// Caché persistido en disco de colores por artwork: evita re-descargar
  /// la portada entre sesiones solo para re-extraer la paleta. Opcional y
  /// best-effort (si no está, se descarga igual).
  final PaletteCacheStore? paletteCache;

  /// Caché de bytes de artwork en disco (evita re-descargar portadas).
  final ArtworkCacheService? artworkCache;

  StreamSubscription<Track?>? _sub;

  /// Caché de color por URL de portada (varias pistas del mismo álbum
  /// comparten portada → no repetir la descarga/análisis).
  final Map<String, Color?> _paletteCache = {};

  Color? _accentColor;
  Color? get accentColor => _accentColor;

  /// Acento "de transporte": el mismo tono que usa TODO el tema (play,
  /// sliders, botones activos), generado sembrando el ColorScheme con el
  /// color del artwork igual que hace `_buildTheme`. El color crudo de la
  /// paleta suele ser darkVibrant (oscuro a propósito) y desentonaba más
  /// oscuro frente al resto. Se cachea: solo se recalcula al cambiar.
  Color? _seededPrimary;
  Color? _seededFor;

  Color get seededPrimary {
    final seed = _accentColor ?? kDefaultAccent;
    if (_seededFor != seed) {
      _seededPrimary = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ).primary;
      _seededFor = seed;
    }
    return _seededPrimary!;
  }

  /// Token anti-carrera: si el usuario cambia de pista mientras se analiza
  /// una portada, se descarta el resultado obsoleto.
  int _token = 0;

  /// Debounce de cambio de pista: el reproductor publica primero el track
  /// de YouTube y poco después el enriquecido con Deezer (portada distinta).
  /// Esperar un instante evita extraer la paleta dos veces seguidas (que el
  /// acento "parpadee" del color de la miniatura al de la portada real) y
  /// descargar dos portadas cuando gana el enriquecimiento.
  Timer? _debounce;

  void _onTrackChanged(Track? track) {
    final token = ++_token;
    final url = track?.thumbnailUrl;
    final urlPreview = url != null ? url.substring(0, math.min(60, url.length)) : 'null';
    print('[SCRUP] _onTrackChanged: ${track?.title ?? "null"} url=$urlPreview');
    if (url == null) {
      _debounce?.cancel();
      _setAccent(null);
      return;
    }

    // Acierto de caché → aplicar YA, sin debounce.
    final stored = paletteCache?.get(url);
    print('[SCRUP] _onTrackChanged: paletteCache.get=${stored != null ? '#${stored.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
    if (stored != null) {
      _debounce?.cancel();
      _paletteCache[url] = stored;
      _setAccent(stored);
      return;
    }
    if (_paletteCache.containsKey(url)) {
      _debounce?.cancel();
      final mem = _paletteCache[url];
      print('[SCRUP] _onTrackChanged: memory cache hit=${mem != null ? '#${mem.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
      if (mem != null) _setAccent(mem);
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      print('[SCRUP] _onTrackChanged: previously FAILED, skip');
      _debounce?.cancel();
      _paletteCache[url] = null;
      return;
    }

    print('[SCRUP] _onTrackChanged: no cache → debounce 600ms → extract');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (token != _token) return;
      _extract(token, url);
    });
  }

  void _extract(int token, String url) {
    print('[SCRUP] _extract: checking store for ${url.substring(0, math.min(60, url.length))}…');
    final stored = paletteCache?.get(url);
    if (stored != null) {
      print('[SCRUP] _extract: FOUND in store → #${stored.toARGB32().toRadixString(16).padLeft(8, '0')}');
      _paletteCache[url] = stored;
      _setAccent(stored);
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      print('[SCRUP] _extract: previously FAILED');
      _paletteCache[url] = null;
      return;
    }
    if (_paletteCache.containsKey(url)) {
      final cached = _paletteCache[url];
      print('[SCRUP] _extract: memory cache=${cached != null ? '#${cached.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
      if (cached != null) _setAccent(cached);
      return;
    }
    print('[SCRUP] _extract: not cached → _loadPalette');
    unawaited(_loadPalette(url, token));
  }

  Future<void> _loadPalette(String url, int token) async {
    print('[SCRUP] _loadPalette: START for ${url.substring(0, math.min(60, url.length))}…');
    Color? color;
    try {
      final store = paletteCache;
      if (store != null) {
        await ArtworkPaletteService.trioFor(
          url,
          store,
          artworkCache: artworkCache,
        );
        color = store.get(url);
        print('[SCRUP] _loadPalette: after trioFor → store.get=${color != null ? '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
      } else {
        final resp = await http
            .get(
              Uri.parse(url),
              headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
            )
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        final trio = await ArtworkPaletteService.extractSwatches(
          resp.bodyBytes,
        );
        color = ArtworkPaletteService.accentFromTrio(
          ArtworkPaletteService.pickTrio(trio),
        );
        print('[SCRUP] _loadPalette: fallback path → ${color != null ? '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
      }
    } catch (e) {
      print('[SCRUP] _loadPalette: ERROR $e');
      color = null;
    }
    _paletteCache[url] = color;
    if (color != null) {
      paletteCache?.put(url, color);
      print('[SCRUP] _loadPalette: persisted accent #${color.toARGB32().toRadixString(16).padLeft(8, '0')}');
    } else {
      paletteCache?.markFailed(url);
      print('[SCRUP] _loadPalette: marked FAILED');
    }
    if (token == _token) {
      print('[SCRUP] _loadPalette: setting accent → #${color?.toARGB32().toRadixString(16).padLeft(8, '0')}');
      _setAccent(color);
    } else {
      print('[SCRUP] _loadPalette: STALE (token $token != $_token) → discarded');
    }
  }

  void _setAccent(Color? color) {
    final prev = _accentColor;
    if (prev == color) return;
    _accentColor = color;
    print('[SCRUP] _setAccent: #${prev?.toARGB32().toRadixString(16).padLeft(8, '0')} → #${color?.toARGB32().toRadixString(16).padLeft(8, '0')}');
    notifyListeners();
  }

  /// Elige el color de acento de una paleta: prefiere el vibrante oscuro
  /// (legible sobre negro), luego vibrante, dominante y muted. Si la paleta
  /// es esencialmente MONOCROMA (artwork B/N: ningún swatch con saturación
  /// real), devuelve un plata neutro derivado de la luminancia en vez de
  /// arrastrar el ruido de croma del JPEG (que daba azulados/verdosos
  /// pastel sin relación con la imagen).
  ///
  /// Triple guardia monocroma:
  /// 1. isLightNeutralArtwork (L ≥ 0.80, S ≤ 0.30) → plata clara.
  /// 2. Dominante con sat < 0.22 → plata media (portadas oscuras B/N).
  /// 3. TODOS los swatches con sat < 0.35 → plata (el "más saturado" de
  ///    PaletteGenerator aún es ruido JPEG, no color real).
  static Color? pickAccent(PaletteGenerator palette) {
    final dominant = palette.dominantColor?.color;
    print('[SCRUP] pickAccent: dominant=${dominant != null ? '#${dominant.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
    if (dominant != null) {
      final hsl = HSLColor.fromColor(dominant);
      print('[SCRUP] pickAccent: domSat=${hsl.saturation.toStringAsFixed(3)} domLight=${hsl.lightness.toStringAsFixed(3)}');
      if (isLightNeutralArtwork(dominant)) {
        print('[SCRUP] pickAccent: → LIGHT NEUTRAL guard → silver');
        return neutralSilver(dominant, minLightness: 0.72, maxLightness: 0.88);
      }
      if (hsl.saturation < kMonochromeSaturationThreshold) {
        print('[SCRUP] pickAccent: → DOMINANT MONOCHROME guard (sat ${hsl.saturation.toStringAsFixed(3)} < $kMonochromeSaturationThreshold) → silver');
        return neutralSilver(dominant, minLightness: 0.60, maxLightness: 0.82);
      }
    }
    // Check global: si NINGÚN swatch tiene saturación significativa, la
    // portada es monocroma aunque el dominante esté apenas sobre 0.22.
    final allColors = <Color>[
      if (palette.darkVibrantColor != null) palette.darkVibrantColor!.color,
      if (palette.vibrantColor != null) palette.vibrantColor!.color,
      if (palette.dominantColor != null) palette.dominantColor!.color,
      if (palette.darkMutedColor != null) palette.darkMutedColor!.color,
      if (palette.mutedColor != null) palette.mutedColor!.color,
    ];
    print('[SCRUP] pickAccent: ${allColors.length} PaletteGenerator swatches');
    for (final c in allColors) {
      final h = HSLColor.fromColor(c);
      print('[SCRUP] pickAccent:   #${c.toARGB32().toRadixString(16).padLeft(8, '0')} sat=${h.saturation.toStringAsFixed(3)} light=${h.lightness.toStringAsFixed(3)}');
    }
    if (allColors.isNotEmpty) {
      final maxSat = allColors.fold<double>(
        0,
        (m, c) => math.max(m, HSLColor.fromColor(c).saturation),
      );
      print('[SCRUP] pickAccent: maxSat=${maxSat.toStringAsFixed(3)} threshold=${(kMonochromeSaturationThreshold + 0.13).toStringAsFixed(3)}');
      if (maxSat < kMonochromeSaturationThreshold + 0.13) {
        print('[SCRUP] pickAccent: → GLOBAL MONOCHROME guard → silver');
        return neutralSilver(
          dominant ?? allColors.first,
          minLightness: 0.60,
          maxLightness: 0.82,
        );
      }
    }
    final result = accentFromSwatches(allColors);
    print('[SCRUP] pickAccent: → accentFromSwatches = ${result != null ? '#${result.toARGB32().toRadixString(16).padLeft(8, '0')}' : 'null'}');
    return result;
  }

  /// Umbral de saturación HSL a partir del cual un swatch cuenta como
  /// "color de verdad" (por debajo hay tinte por compresión, no intención
  /// del artista).
  @visibleForTesting
  static const double kMonochromeSaturationThreshold = 0.22;

  /// Umbrales para clasificar una portada como BLANCA/CLARA neutra: el
  /// swatch dominante debe ser muy luminoso y poco saturado.
  @visibleForTesting
  static const double kWhiteCoverLightness = 0.80;
  @visibleForTesting
  static const double kWhiteCoverMaxSaturation = 0.30;

  /// `true` si el swatch dominante representa una imagen esencialmente
  /// blanca/clara y sin color real.
  @visibleForTesting
  static bool isLightNeutralArtwork(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    return hsl.lightness >= kWhiteCoverLightness &&
        hsl.saturation <= kWhiteCoverMaxSaturation;
  }

  /// Plata/blanco neutro derivado de [src]: saturación a CERO (sin ruido de
  /// croma) y luminancia elevada al rango [minLightness, maxLightness].
  @visibleForTesting
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

  /// Selección pura de acento sobre una lista priorizada de swatches.
  /// Expuesta para tests (no depende de PaletteGenerator/imágenes).
  @visibleForTesting
  static Color? accentFromSwatches(List<Color?> swatches) {
    final candidates = swatches.whereType<Color>().toList();
    if (candidates.isEmpty) return null;

    // 1er pase: el primer swatch prioritario con saturación de verdad.
    for (final c in candidates) {
      if (HSLColor.fromColor(c).saturation >= kMonochromeSaturationThreshold) {
        return c;
      }
    }

    // 2º pase: artwork monocromo. Plata neutro legible sobre UI oscura:
    // saturación a CERO (sin ruido de croma) y luminancia elevada desde la
    // del swatch dominante (clamp para que ni desaparezca ni deslumbre).
    return neutralSilver(
      candidates.first,
      minLightness: 0.60,
      maxLightness: 0.82,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
