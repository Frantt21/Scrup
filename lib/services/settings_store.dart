import 'package:shared_preferences/shared_preferences.dart';

/// Guarda preferencias simples de la sesión en disco (shared_preferences):
/// el volumen del reproductor y la última pista que se estaba reproduciendo,
/// para restaurarlas al arrancar.
class SettingsStore {
  static const _volumeKey = 'player.volume';
  static const _lastTrackKey = 'player.last_track_id';
  static const _sidebarGridKey = 'ui.sidebar_grid_mode';
  static const _localeKey = 'app.locale';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> saveVolume(double volume) async {
    final prefs = await _instance;
    await prefs.setDouble(_volumeKey, volume);
  }

  Future<double?> loadVolume() async {
    final prefs = await _instance;
    return prefs.getDouble(_volumeKey);
  }

  Future<void> saveSidebarGridMode(bool grid) async {
    final prefs = await _instance;
    await prefs.setBool(_sidebarGridKey, grid);
  }

  /// `null` si el usuario nunca cambió el modo (por defecto: lista).
  Future<bool?> loadSidebarGridMode() async {
    final prefs = await _instance;
    return prefs.getBool(_sidebarGridKey);
  }

  Future<void> saveLastTrackId(String id) async {
    final prefs = await _instance;
    await prefs.setString(_lastTrackKey, id);
  }

  Future<String?> loadLastTrackId() async {
    final prefs = await _instance;
    return prefs.getString(_lastTrackKey);
  }

  /// Guarda el idioma de la interfaz (código BCP-47, p. ej. `es`, `en`).
  Future<void> saveLocale(String languageCode) async {
    final prefs = await _instance;
    await prefs.setString(_localeKey, languageCode);
  }

  /// `null` si el usuario nunca cambió el idioma (por defecto: español).
  Future<String?> loadLocale() async {
    final prefs = await _instance;
    return prefs.getString(_localeKey);
  }
}
