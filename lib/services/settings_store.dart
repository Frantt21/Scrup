import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda preferencias simples de la sesión en disco (shared_preferences)
/// para restaurarlas al arrancar: volumen, modo shuffle y modo de repetición
/// del reproductor, la cola completa (orden, orden pre-shuffle, índice y
/// playlist activa), el punto de reanudación (pista + segundos), la última
/// pista reproducida como respaldo, modo del sidebar, idioma, estado del
/// panel de cola, animación del player y presencia de Discord.
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
  static const _resumeKey = 'player.resume';

  /// Clave compartida con forawn_mobile (el widget de lyrics la lee igual).
  static const lyricsSweepKey = 'lyrics_sweep_enabled';

  /// Preferencia en memoria de la animación del player: un [ValueNotifier]
  /// para que el PlayerBar reaccione al instante al alternarla desde
  /// Configuración (el valor también se persiste entre sesiones).
  final ValueNotifier<bool> playerAnimationEnabled = ValueNotifier(true);

  /// Preferencia en memoria del modo karaoke (sweep palabra por palabra) de
  /// los lyrics: la lee el widget de lyrics al abrir/cambiar de canción.
  final ValueNotifier<bool> lyricsSweepEnabled = ValueNotifier(false);

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

  /// Guarda el modo karaoke (sweep) de los lyrics y lo refleja en el
  /// [ValueNotifier] para que el widget de lyrics reaccione al instante.
  Future<void> setLyricsSweepEnabled(bool enabled) async {
    lyricsSweepEnabled.value = enabled;
    final prefs = await _instance;
    await prefs.setBool(lyricsSweepKey, enabled);
  }

  /// Carga la preferencia del modo karaoke (por defecto: desactivado).
  Future<bool> loadLyricsSweepEnabled() async {
    final prefs = await _instance;
    final saved = prefs.getBool(lyricsSweepKey);
    final value = saved ?? false;
    lyricsSweepEnabled.value = value;
    return value;
  }

  // ── Omitir silencios ──────────────────────────────────────────────

  static const _skipSilenceKey = 'player.skip_silence';

  /// Preferencia en memoria de "omitir silencios": un [ValueNotifier] para
  /// que el SilenceSkipService reaccione al instante (el valor también se
  /// persiste entre sesiones). Por defecto ACTIVA.
  final ValueNotifier<bool> skipSilenceEnabled = ValueNotifier(true);

  Future<void> setSkipSilenceEnabled(bool enabled) async {
    skipSilenceEnabled.value = enabled;
    final prefs = await _instance;
    await prefs.setBool(_skipSilenceKey, enabled);
  }

  Future<bool> loadSkipSilenceEnabled() async {
    final prefs = await _instance;
    final saved = prefs.getBool(_skipSilenceKey);
    final value = saved ?? true;
    skipSilenceEnabled.value = value;
    return value;
  }

  // ── Lyrics sync offset ────────────────────────────────────────────

  /// Offsets POR PISTA: `{trackId: ms}` en una sola clave JSON. Cada canción
  /// recuerda su propio ajuste de sincronía (cambiar la fuente de la letra o
  /// re-buscarla NO lo pierde). Sin ajuste propio el offset es cero: el
  /// global legacy (`lyrics_sync_offset_ms`) NUNCA se aplica como fallback
  /// (era un ajuste de UNA canción y contaminaba a todas las demás).
  static const _lyricsOffsetsKey = 'lyrics_offsets_v1';

  Map<String, int> _decodeOffsets(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), v is int ? v : 0),
        )..removeWhere((_, v) => v == 0);
      }
    } catch (_) {}
    return {};
  }

  /// Guarda el offset de sincronización de UNA pista. Cero lo elimina del
  /// mapa (sin entradas huérfanas).
  Future<void> saveLyricsOffsetFor(String trackId, Duration offset) async {
    final prefs = await _instance;
    final map = _decodeOffsets(prefs.getString(_lyricsOffsetsKey));
    if (offset == Duration.zero) {
      map.remove(trackId);
    } else {
      map[trackId] = offset.inMilliseconds;
    }
    await prefs.setString(_lyricsOffsetsKey, jsonEncode(map));
  }

  /// `true` si la pista tiene ENTRADA PROPIA en el mapa de offsets: distingue
  /// «el usuario puso 0» (imposible: cero elimina la entrada) de «nunca se
  /// tocó». Lo usa el auto-offset de SponsorBlock para saber si puede
  /// absorberse en la raíz sin pisar un valor ya puesto a mano.
  Future<bool> hasLyricsOffsetFor(String trackId) async {
    final prefs = await _instance;
    return _decodeOffsets(prefs.getString(_lyricsOffsetsKey))
        .containsKey(trackId);
  }

  /// Carga el offset de sincronización de UNA pista (cero si nunca se
  /// ajustó esa canción).
  Future<Duration> loadLyricsOffsetFor(String trackId) async {
    final prefs = await _instance;
    final ms = _decodeOffsets(prefs.getString(_lyricsOffsetsKey))[trackId];
    return ms != null ? Duration(milliseconds: ms) : Duration.zero;
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

  /// Guarda el punto de reanudación: el id de la pista y su posición en
  /// segundos, en UN SOLO write (JSON). Así una posición nunca se restaura
  /// en una pista distinta aunque el guardado vaya con retraso (p. ej. el
  /// debounce de posición) respecto al cambio de pista.
  Future<void> saveResumePosition(int seconds, String trackId) async {
    final prefs = await _instance;
    await prefs.setString(
      _resumeKey,
      jsonEncode({'trackId': trackId, 'seconds': seconds}),
    );
  }

  /// `null` si nunca se guardó o el dato guardado es ilegible (se ignora).
  Future<({String trackId, int seconds})?> loadResumePosition() async {
    final prefs = await _instance;
    final raw = prefs.getString(_resumeKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return (
        trackId: map['trackId'] as String,
        seconds: map['seconds'] as int,
      );
    } catch (_) {
      return null; // Dato corrupto → se ignora.
    }
  }
}
