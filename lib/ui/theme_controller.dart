import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';

import '../core/track.dart';
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
  ThemeController(this._player, {this.paletteCache}) {
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

  StreamSubscription<Track?>? _sub;

  /// Caché de color por URL de portada (varias pistas del mismo álbum
  /// comparten portada → no repetir la descarga/análisis).
  final Map<String, Color?> _paletteCache = {};

  Color? _accentColor;
  Color? get accentColor => _accentColor;

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
    if (url == null) {
      _debounce?.cancel();
      _setAccent(null);
      return;
    }

    // Acierto de caché → aplicar YA, sin debounce. El color suele conocerse
    // de antemano (extraído por el detalle de la playlist o en una sesión
    // anterior): esperar aquí era lo que hacía sentir que "el player no
    // sabía el color" de la pista. El debounce SOLO aplica cuando toca
    // descargar/analizar la portada.
    final stored = paletteCache?.get(url);
    if (stored != null) {
      _debounce?.cancel();
      _paletteCache[url] = stored;
      _setAccent(stored);
      return;
    }
    if (_paletteCache.containsKey(url)) {
      _debounce?.cancel();
      final mem = _paletteCache[url];
      if (mem != null) _setAccent(mem);
      return;
    }
    // Fallo ya conocido: no hay nada mejor que el acento actual.
    if (paletteCache?.isFailed(url) ?? false) {
      _debounce?.cancel();
      _paletteCache[url] = null;
      return;
    }

    // Sin caché: descargar con debounce. El reproductor publica primero el
    // track de YouTube y poco después el enriquecido con Deezer (portada
    // distinta): esperar un instante evita analizar dos portadas seguidas.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (token != _token) return;
      _extract(token, url);
    });
  }

  void _extract(int token, String url) {
    // Caché compartido (playlist/sesiones anteriores): el color ya extraído
    // por el detalle de una playlist se aplica aquí sin re-descargar.
    final stored = paletteCache?.get(url);
    if (stored != null) {
      _paletteCache[url] = stored;
      _setAccent(stored);
      return;
    }
    // Alguien (otra vista o nosotros) ya intentó esta portada y falló en
    // esta sesión: no volver a descargarla (se mantiene el acento actual).
    if (paletteCache?.isFailed(url) ?? false) {
      _paletteCache[url] = null;
      return;
    }
    // containsKey: también se cachea el fallo (null) para no re-descargar
    // la misma portada fallida cada vez que suena la pista.
    if (_paletteCache.containsKey(url)) {
      final cached = _paletteCache[url];
      if (cached != null) _setAccent(cached);
      return;
    }
    unawaited(_loadPalette(url, token));
  }

  Future<void> _loadPalette(String url, int token) async {
    Color? color;
    try {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final palette = await PaletteGenerator.fromImageProvider(
        MemoryImage(resp.bodyBytes),
        maximumColorCount: 16,
      );
      color = pickAccent(palette);
    } catch (_) {
      color = null;
    }
    // Guardar aunque sea null para no reintentar la misma portada fallida.
    _paletteCache[url] = color;
    if (color != null) {
      // Persistir en disco solo los éxitos (los fallos se reintentan luego).
      paletteCache?.put(url, color);
    } else {
      // Compartir el fallo con el resto de la app en esta sesión.
      paletteCache?.markFailed(url);
    }
    if (token == _token) _setAccent(color);
  }

  void _setAccent(Color? color) {
    if (_accentColor == color) return;
    _accentColor = color;
    notifyListeners();
  }

  /// Elige el color de acento de una paleta: prefiere el vibrante oscuro
  /// (legible sobre negro), luego vibrante, dominante y muted. Si la paleta
  /// es esencialmente MONOCROMA (artwork B/N: ningún swatch con saturación
  /// real), devuelve un plata neutro derivado de la luminancia en vez de
  /// arrastrar el ruido de croma del JPEG (que daba azulados/verdosos
  /// pastel sin relación con la imagen).
  static Color? pickAccent(PaletteGenerator palette) {
    return accentFromSwatches([
      palette.darkVibrantColor?.color,
      palette.vibrantColor?.color,
      palette.dominantColor?.color,
      palette.darkMutedColor?.color,
      palette.mutedColor?.color,
    ]);
  }

  /// Umbral de saturación HSL a partir del cual un swatch cuenta como
  /// "color de verdad" (por debajo hay tinte por compresión, no intención
  /// del artista).
  @visibleForTesting
  static const double kMonochromeSaturationThreshold = 0.22;

  /// Selección pura de acento sobre una lista priorizada de swatches.
  /// Expuesta para tests (no depende de PaletteGenerator/imágenes).
  @visibleForTesting
  static Color? accentFromSwatches(List<Color?> swatches) {
    final candidates = swatches.whereType<Color>().toList();
    if (candidates.isEmpty) return null;

    // 1er pase: el primer swatch prioritario con saturación de verdad.
    for (final c in candidates) {
      if (HSLColor.fromColor(c).saturation >=
          kMonochromeSaturationThreshold) {
        return c;
      }
    }

    // 2º pase: artwork monocromo. Plata neutro legible sobre UI oscura:
    // saturación a CERO (sin ruido de croma) y luminancia elevada desde la
    // del swatch dominante (clamp para que ni desaparezca ni deslumbre).
    final hsl = HSLColor.fromColor(candidates.first);
    return hsl
        .withSaturation(0)
        .withLightness(hsl.lightness.clamp(0.60, 0.82))
        .toColor();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
