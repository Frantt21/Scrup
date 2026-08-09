import 'package:shared_preferences/shared_preferences.dart';

/// Guarda preferencias simples de la sesión en disco (shared_preferences):
/// el volumen del reproductor y la última pista que se estaba reproduciendo,
/// para restaurarlas al arrancar.
class SettingsStore {
  static const _volumeKey = 'player.volume';
  static const _lastTrackKey = 'player.last_track_id';
  static const _sidebarGridKey = 'ui.sidebar_grid_mode';
  static const _localeKey = 'app.locale';
  static const _discordEnabledKey = 'discord.enabled';
  static const _discordClientIdKey = 'discord.client_id';

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

  /// Guarda el idioma de la interfaz (código BCP-47 completo, con posible
  /// región: `es`, `en`, `pt_BR`).
  Future<void> saveLocale(String localeString) async {
    final prefs = await _instance;
    await prefs.setString(_localeKey, localeString);
  }

  /// `null` si el usuario nunca cambió el idioma (por defecto: español).
  Future<String?> loadLocale() async {
    final prefs = await _instance;
    return prefs.getString(_localeKey);
  }

  /// Presencia de Discord activa (por defecto: desactivada — requiere que el
  /// usuario cree una aplicación y pegue su id en Discord Developer Portal).
  Future<void> saveDiscordEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_discordEnabledKey, enabled);
  }

  Future<bool> loadDiscordEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_discordEnabledKey) ?? false;
  }

  /// Id de aplicación de Discord (se pega desde Discord Developer Portal).
  Future<void> saveDiscordClientId(String clientId) async {
    final prefs = await _instance;
    await prefs.setString(_discordClientIdKey, clientId);
  }

  Future<String?> loadDiscordClientId() async {
    final prefs = await _instance;
    return prefs.getString(_discordClientIdKey);
  }
}
