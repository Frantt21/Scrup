import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda preferencias simples de la sesión en disco (shared_preferences)
/// para restaurarlas al arrancar: volumen, modo shuffle y modo de repetición
/// del reproductor, la cola completa (orden, orden pre-shuffle, índice y
/// playlist activa), la última pista reproducida como respaldo, modo del
/// sidebar, idioma, estado del panel de cola, animación del player y
/// presencia de Discord.
class SettingsStore {
  static const _volumeKey = 'player.volume';
  static const _lastTrackKey = 'player.last_track_id';
  static const _sidebarGridKey = 'ui.sidebar_grid_mode';
  static const _localeKey = 'app.locale';
  static const _discordEnabledKey = 'discord.enabled';
  static const _queueOpenKey = 'ui.queue_open';
  static const _playerAnimationKey = 'player.animation_enabled';
  static const _shuffleEnabledKey = 'player.shuffle_enabled';
  static const _repeatModeKey = 'player.repeat_mode';
  static const _queueKey = 'player.queue_ids';
  static const _originalQueueKey = 'player.queue_original_ids';
  static const _queueIndexKey = 'player.queue_index';
  static const _activePlaylistIdKey = 'player.active_playlist_id';

  /// Preferencia en memoria de la animación del player: un [ValueNotifier]
  /// para que el PlayerBar reaccione al instante al alternarla desde
  /// Configuración (el valor también se persiste entre sesiones).
  final ValueNotifier<bool> playerAnimationEnabled = ValueNotifier(true);

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

  /// Presencia de Discord activa (por defecto: desactivada; el id de
  /// aplicación está embebido en el cliente, solo hay que activar el toggle).
  Future<void> saveDiscordEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_discordEnabledKey, enabled);
  }

  Future<bool> loadDiscordEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_discordEnabledKey) ?? false;
  }

  /// Estado abierto/cerrado del panel de la cola (para restaurarlo al
  /// arrancar). `null` si el usuario nunca lo tocó (por defecto: cerrado).
  Future<void> saveQueueOpen(bool open) async {
    final prefs = await _instance;
    await prefs.setBool(_queueOpenKey, open);
  }

  Future<bool?> loadQueueOpen() async {
    final prefs = await _instance;
    return prefs.getBool(_queueOpenKey);
  }

  /// Activa/desactiva la animación del player: actualiza el [ValueNotifier]
  /// (reacción inmediata en el reproductor) y persiste en disco.
  Future<void> setPlayerAnimationEnabled(bool enabled) async {
    playerAnimationEnabled.value = enabled;
    final prefs = await _instance;
    await prefs.setBool(_playerAnimationKey, enabled);
  }

  /// Carga la preferencia de animación (por defecto: activa) y la refleja en
  /// el [ValueNotifier] para el resto del app.
  Future<bool> loadPlayerAnimationEnabled() async {
    final prefs = await _instance;
    final saved = prefs.getBool(_playerAnimationKey);
    final value = saved ?? true;
    playerAnimationEnabled.value = value;
    return value;
  }

  /// Guarda el modo shuffle activo/desactivado para restaurarlo entre
  /// sesiones.
  Future<void> saveShuffleEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_shuffleEnabledKey, enabled);
  }

  /// `null` si el usuario nunca cambió el modo (por defecto: desactivado).
  Future<bool?> loadShuffleEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_shuffleEnabledKey);
  }

  /// Guarda el modo de repetición (nombre del enum `LoopMode`: `off`,
  /// `all` o `one`) para restaurarlo entre sesiones.
  Future<void> saveRepeatMode(String mode) async {
    final prefs = await _instance;
    await prefs.setString(_repeatModeKey, mode);
  }

  /// `null` si el usuario nunca cambió el modo (por defecto: `off`).
  Future<String?> loadRepeatMode() async {
    final prefs = await _instance;
    return prefs.getString(_repeatModeKey);
  }

  /// Guarda los ids de la cola en su ORDEN actual (para reanudarla al
  /// arrancar). Una lista vacía limpia la cola guardada.
  Future<void> saveQueue(List<String> ids) async {
    final prefs = await _instance;
    await prefs.setStringList(_queueKey, ids);
  }

  /// `null` si nunca se guardó una cola.
  Future<List<String>?> loadQueue() async {
    final prefs = await _instance;
    return prefs.getStringList(_queueKey);
  }

  /// Guarda el orden ORIGINAL de la cola (pre-shuffle) si lo hay, o limpia
  /// la clave pasando `null`.
  Future<void> saveOriginalQueue(List<String>? ids) async {
    final prefs = await _instance;
    if (ids == null) {
      await prefs.remove(_originalQueueKey);
    } else {
      await prefs.setStringList(_originalQueueKey, ids);
    }
  }

  Future<List<String>?> loadOriginalQueue() async {
    final prefs = await _instance;
    return prefs.getStringList(_originalQueueKey);
  }

  /// Guarda el índice de la pista actual dentro de la cola.
  Future<void> saveQueueIndex(int index) async {
    final prefs = await _instance;
    await prefs.setInt(_queueIndexKey, index);
  }

  Future<int?> loadQueueIndex() async {
    final prefs = await _instance;
    return prefs.getInt(_queueIndexKey);
  }

  /// Guarda la playlist de la que viene la cola (o limpia la clave pasando
  /// `null` si la reproducción no viene de una playlist).
  Future<void> saveActivePlaylistId(int? id) async {
    final prefs = await _instance;
    if (id == null) {
      await prefs.remove(_activePlaylistIdKey);
    } else {
      await prefs.setInt(_activePlaylistIdKey, id);
    }
  }

  Future<int?> loadActivePlaylistId() async {
    final prefs = await _instance;
    return prefs.getInt(_activePlaylistIdKey);
  }
}
