import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';

import '../core/track.dart';
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
  ThemeController(this._player) {
    // Leer la pista ya publicada (p. ej. sesión restaurada): los streams
    // broadcast no re-emiten lo pasado, así que el acento se aplica aquí.
    _onTrackChanged(_player.currentTrackValue);
    _sub = _player.currentTrack.listen(_onTrackChanged);
  }

  final PlayerService _player;
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
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (token != _token) return;
      _extract(token, url);
    });
  }

  void _extract(int token, String url) {
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
    if (token == _token) _setAccent(color);
  }

  void _setAccent(Color? color) {
    if (_accentColor == color) return;
    _accentColor = color;
    notifyListeners();
  }

  /// Elige el color de acento de una paleta: prefiere el vibrante oscuro
  /// (legible sobre negro), luego vibrante, dominante y muted.
  static Color? pickAccent(PaletteGenerator palette) {
    final candidates = [
      palette.darkVibrantColor,
      palette.vibrantColor,
      palette.dominantColor,
      palette.darkMutedColor,
      palette.mutedColor,
    ];
    for (final c in candidates) {
      if (c != null) return c.color;
    }
    return null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
