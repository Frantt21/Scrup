import 'package:shared_preferences/shared_preferences.dart';

/// Guarda preferencias simples de la sesión en disco (shared_preferences):
/// el volumen del reproductor y la última pista que se estaba reproduciendo,
/// para restaurarlas al arrancar.
class SettingsStore {
  static const _volumeKey = 'player.volume';
  static const _lastTrackKey = 'player.last_track_id';

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

  Future<void> saveLastTrackId(String id) async {
    final prefs = await _instance;
    await prefs.setString(_lastTrackKey, id);
  }

  Future<String?> loadLastTrackId() async {
    final prefs = await _instance;
    return prefs.getString(_lastTrackKey);
  }
}
