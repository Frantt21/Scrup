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

/// Saturación por debajo de la cual una semilla se trata como NEUTRA en
/// `seededPrimary`: pasarla por `ColorScheme.fromSeed` le inventaría el hue
/// baseline de M3 (azulado). La plata del guard monocromo tiene sat 0.
const double kDefaultAccentNeutralThreshold = 0.10;

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
  ///
  /// SEMILLA NEUTRA: si el acento es plata/neutro (artwork B/N), NO se pasa
  /// por `ColorScheme.fromSeed` — Material 3 inventa el hue "baseline"
  /// azulado para semillas acromáticas (un gris → primary azul-grisáceo) y
  /// los controles se teñían de azul sin relación con la portada.
  Color? _seededPrimary;
  Color? _seededFor;

  Color get seededPrimary {
    final seed = _accentColor ?? kDefaultAccent;
    if (_seededFor != seed) {
      if (HSLColor.fromColor(seed).saturation < kDefaultAccentNeutralThreshold) {
        _seededPrimary = seed;
      } else {
        _seededPrimary = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ).primary;
      }
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

  /// Delay mínimo antes de aplicar el color de acento. Separa la fase 1
  /// (artwork + track info) de la fase 2 (accent rebuild) en frames
  /// distintos, aliviando la carga de rendering en Linux.
  static const Duration kAccentDelay = Duration(milliseconds: 70);

  void _onTrackChanged(Track? track) {
    final token = ++_token;
    final url = track?.thumbnailUrl;

    // Cancelar cualquier debounce anterior: solo el ÚLTIMO color gana.
    _debounce?.cancel();

    if (url == null) {
      _debounce = Timer(kAccentDelay, () {
        if (token == _token) _setAccent(null);
      });
      return;
    }

    // Buscar color en caché (SQLite → memoria → failed).
    final stored = paletteCache?.get(url);
    if (stored != null) {
      _paletteCache[url] = stored;
      _debounce = Timer(kAccentDelay, () {
        if (token == _token) _setAccent(stored);
      });
      return;
    }
    if (_paletteCache.containsKey(url)) {
      final mem = _paletteCache[url];
      if (mem != null) {
        _debounce = Timer(kAccentDelay, () {
          if (token == _token) _setAccent(mem);
        });
      }
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      _paletteCache[url] = null;
      return;
    }

    // Sin caché → extraer en background (600ms debounce para Deezer
    // enrichment). El resultado se aplica con el mismo delay mínimo.
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (token != _token) return;
      _extract(token, url);
    });
  }

  void _extract(int token, String url) {
    final stored = paletteCache?.get(url);
    if (stored != null) {
      _paletteCache[url] = stored;
      _debounce = Timer(kAccentDelay, () {
        if (token == _token) _setAccent(stored);
      });
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      _paletteCache[url] = null;
      return;
    }
    if (_paletteCache.containsKey(url)) {
      final cached = _paletteCache[url];
      if (cached != null) {
        _debounce = Timer(kAccentDelay, () {
          if (token == _token) _setAccent(cached);
        });
      }
      return;
    }
    unawaited(_loadPalette(url, token));
  }

  Future<void> _loadPalette(String url, int token) async {
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
      }
    } catch (_) {
      color = null;
    }
    _paletteCache[url] = color;
    if (color != null) {
      paletteCache?.put(url, color);
    } else {
      paletteCache?.markFailed(url);
    }
    if (token == _token) _setAccent(color);
  }

  void _setAccent(Color? color) {
    final prev = _accentColor;
    if (prev == color) return;
    _accentColor = color;
    _seededFor = null;
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
    if (dominant != null) {
      final hsl = HSLColor.fromColor(dominant);
      if (isLightNeutralArtwork(dominant)) {
        return neutralSilver(dominant, minLightness: 0.72, maxLightness: 0.88);
      }
      if (hsl.saturation < kMonochromeSaturationThreshold) {
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
    if (allColors.isNotEmpty) {
      final maxSat = allColors.fold<double>(
        0,
        (m, c) => math.max(m, HSLColor.fromColor(c).saturation),
      );
      if (maxSat < kMonochromeSaturationThreshold + 0.13) {
        return neutralSilver(
          dominant ?? allColors.first,
          minLightness: 0.60,
          maxLightness: 0.82,
        );
      }
    }
    final result = accentFromSwatches(allColors);
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
