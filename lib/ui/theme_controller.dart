import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';

import '../core/track.dart';
import '../core/app_log.dart';
import '../services/artwork_cache_service.dart';
import '../services/artwork_palette_service.dart';
import '../services/palette_cache_store.dart';
import '../services/player_service.dart';

const Color kDefaultAccent = Color(0xFFC084FC);

const double kDefaultAccentNeutralThreshold = 0.10;

/// Derives the app accent color from the current track's artwork.
class ThemeController extends ChangeNotifier {
  ThemeController(this._player, {this.paletteCache, this.artworkCache}) {
    _onTrackChanged(_player.currentTrackValue);
    _sub = _player.currentTrack.listen(_onTrackChanged);
    // La cola ya sabe cuál es la siguiente pista: se precarga su acento
    // (y de paso su artwork en disco) para que al cambiar de canción el
    // color esté en caché y la transición no pase por el lila por defecto.
    _player.queue.addListener(_onQueueChanged);
    _player.queueIndex.addListener(_onQueueChanged);
    _onQueueChanged();
  }

  final PlayerService _player;

  final PaletteCacheStore? paletteCache;

  final ArtworkCacheService? artworkCache;

  StreamSubscription<Track?>? _sub;

  final Map<String, Color?> _paletteCache = {};

  Color? _accentColor;
  Color? get accentColor => _accentColor;

  Color? _seededPrimary;
  Color? _seededFor;

  Color get seededPrimary {
    final seed = _accentColor ?? kDefaultAccent;
    if (_seededFor != seed) {
      if (HSLColor.fromColor(seed).saturation <
          kDefaultAccentNeutralThreshold) {
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

  int _token = 0;

  Timer? _debounce;

  static const Duration kAccentDelay = Duration(milliseconds: 70);

  void _onTrackChanged(Track? track) {
    final token = ++_token;
    final url = track?.thumbnailUrl;
    appLog(
      'ACCENT',
      'track=${shortId(track?.id)} url=${shortUrl(url)} '
      'tok=$token cur=${colorHex(_accentColor)}',
    );

    _debounce?.cancel();

    if (url == null) {
      // El reproductor emite `null` en CADA cambio de canción mientras
      // prepara la siguiente (no solo al detenerse). Si aquí se pusiera el
      // acento en null, el fondo pasaría por el color neutro de respaldo
      // entre pista y pista ("parpadeo" de colores intermedios). Se mantiene
      // el acento actual; solo si de verdad se queda sin pista (1.5s sin una
      // nueva) se vuelve al default.
      _debounce = Timer(const Duration(milliseconds: 1500), () {
        if (token == _token && _player.currentTrackValue == null) {
          _setAccent(null);
        }
      });
      return;
    }

    final stored = paletteCache?.get(url);
    if (stored != null) {
      appLog('ACCENT', 'STORE-HIT ${shortUrl(url)} → ${colorHex(stored)} (70ms)');
      _paletteCache[url] = stored;
      _debounce = Timer(kAccentDelay, () {
        if (token == _token) _setAccent(stored);
      });
      return;
    }
    if (_paletteCache.containsKey(url)) {
      final mem = _paletteCache[url];
      appLog('ACCENT', 'MEM ${shortUrl(url)} → ${colorHex(mem)}');
      if (mem != null) {
        _debounce = Timer(kAccentDelay, () {
          if (token == _token) _setAccent(mem);
        });
      }
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      appLog('ACCENT', 'FAILED-mark ${shortUrl(url)} → HOLD ${colorHex(_accentColor)}');
      _paletteCache[url] = null;
      return;
    }

    appLog('ACCENT', 'MISS ${shortUrl(url)} → extract en 600ms');
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (token != _token) return;
      _extract(token, url);
    });
  }

  void _extract(int token, String url) {
    final stored = paletteCache?.get(url);
    if (stored != null) {
      appLog('ACCENT', 'EXTRACT store-hit tardío ${shortUrl(url)}');
      _paletteCache[url] = stored;
      _debounce = Timer(kAccentDelay, () {
        if (token == _token) _setAccent(stored);
      });
      return;
    }
    if (paletteCache?.isFailed(url) ?? false) {
      appLog('ACCENT', 'EXTRACT failed-mark tardío ${shortUrl(url)} → HOLD');
      _paletteCache[url] = null;
      return;
    }
    if (_paletteCache.containsKey(url)) {
      final cached = _paletteCache[url];
      appLog('ACCENT', 'EXTRACT mem tardía ${shortUrl(url)} → ${colorHex(cached)}');
      if (cached != null) {
        _debounce = Timer(kAccentDelay, () {
          if (token == _token) _setAccent(cached);
        });
      }
      return;
    }
    appLog('ACCENT', 'EXTRACT fetch red ${shortUrl(url)}');
    unawaited(_loadPalette(url, token));
  }

  Future<void> _loadPalette(String url, int token) async {
    final t0 = DateTime.now();
    Color? color;
    try {
      final store = paletteCache;
      if (store != null) {
        // Ruta BARATA: un solo color del artwork (sin tríos), cacheado por
        // URL. Extrae con un único salto y sin retintar toda la app.
        color = await ArtworkPaletteService.accentFor(
          url,
          store,
          artworkCache: artworkCache,
        );
      } else {
        final resp = await http
            .get(
              Uri.parse(url),
              headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
            )
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        final swatches = await ArtworkPaletteService.extractSwatches(
          resp.bodyBytes,
        );
        color = ArtworkPaletteService.accentFromSwatches(swatches);
      }
    } catch (_) {
      color = null;
    }
    _paletteCache[url] = color;
    final ms = DateTime.now().difference(t0).inMilliseconds;
    if (color != null) {
      paletteCache?.put(url, color);
    } else {
      paletteCache?.markFailed(url);
    }
    appLog(
      'ACCENT',
      'FETCH ${shortUrl(url)} → ${colorHex(color)} en ${ms}ms '
      'tok=$token curTok=$_token',
    );
    // Si la extracción falla, se CONSERVA el acento anterior: ponerlo en
    // null haría que el player/miniplayer cayeran al lila por defecto en
    // mitad de la transición entre canciones.
    if (token == _token && color != null) _setAccent(color);
  }

  /// URLs con precarga de acento en curso (evita descargas duplicadas).
  final Set<String> _warming = {};

  /// Precarga el acento de las 2 pistas siguientes de la cola (sin tocar el
  /// acento visible). Como efecto colateral también deja el artwork en el
  /// caché de disco ([ArtworkCacheService]).
  void _onQueueChanged() {
    final queue = _player.queue.value;
    final index = _player.queueIndex.value;
    if (queue.isEmpty) return;
    final upcoming = <String>[];
    for (var i = 1; i <= 2; i++) {
      final next = index + i;
      if (next < 0 || next >= queue.length) break;
      upcoming.add(shortId(queue[next].id));
      warmAccent(queue[next].thumbnailUrl);
    }
    if (upcoming.isNotEmpty) {
      appLog('WARM', 'cola idx=$index → warm $upcoming');
    }
  }

  /// Prepara el acento de [url] en caché sin cambiar el color visible.
  /// Es seguro llamarlo desde los widgets cuando aparece una pista "en
  /// preparación": si el color ya está listo, el cambio de canción lo toma
  /// al instante y no hay paso por el color por defecto.
  void warmAccent(String? url) {
    if (url == null || url.isEmpty) return;
    final store = paletteCache;
    if (store == null) return;
    if (store.get(url) != null) return;
    if (_paletteCache.containsKey(url)) return;
    if (store.isFailed(url)) return;
    if (!_warming.add(url)) return;
    appLog('WARM', 'start ${shortUrl(url)}');
    unawaited(
      ArtworkPaletteService.accentFor(
        url,
        store,
        artworkCache: artworkCache,
      ).then((color) {
        appLog('WARM', 'done ${shortUrl(url)} → ${colorHex(color)}');
        if (color != null) {
          _paletteCache[url] = color;
          // accentFor ya lo guardó en el store.
        } else {
          store.markFailed(url);
        }
      }).catchError((_) => null).whenComplete(() => _warming.remove(url)),
    );
  }

  void _setAccent(Color? color) {
    final prev = _accentColor;
    if (prev == color) return;
    appLog('ACCENT', 'SET ${colorHex(prev)} → ${colorHex(color)}');
    _accentColor = color;
    _seededFor = null;
    notifyListeners();
  }

  void setAccent(Color? color) => _setAccent(color);

  // Invalidates cached color for URL (for manual recalculation).
  void invalidateColor(String url) {
    _paletteCache.remove(url);
  }

  // Picks accent from palette: prefers vibrant, falls back to silver
  // for monochrome artwork.
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

  @visibleForTesting
  static const double kMonochromeSaturationThreshold = 0.22;

  @visibleForTesting
  static const double kWhiteCoverLightness = 0.80;
  @visibleForTesting
  static const double kWhiteCoverMaxSaturation = 0.30;

  @visibleForTesting
  static bool isLightNeutralArtwork(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    return hsl.lightness >= kWhiteCoverLightness &&
        hsl.saturation <= kWhiteCoverMaxSaturation;
  }

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

  @visibleForTesting
  static Color? accentFromSwatches(List<Color?> swatches) =>
      ArtworkPaletteService.accentFromSwatches(swatches);

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _player.queue.removeListener(_onQueueChanged);
    _player.queueIndex.removeListener(_onQueueChanged);
    super.dispose();
  }
}
