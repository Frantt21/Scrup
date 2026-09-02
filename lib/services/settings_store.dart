import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists user preferences across sessions via SharedPreferences.
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
  static const _radioEnabledKey = 'player.radio_enabled';
  static const _queueKey = 'player.queue_ids';
  static const _originalQueueKey = 'player.queue_original_ids';
  static const _queueIndexKey = 'player.queue_index';
  static const _activePlaylistIdKey = 'player.active_playlist_id';
  static const _flatPlaylistHeaderKey = 'ui.flat_playlist_header';
  static const _resumeKey = 'player.resume';  static const _cacheMaxSizeKey = 'cache.max_size_mb';  static const lyricsSweepKey = 'lyrics_sweep_enabled';  final ValueNotifier<bool> playerAnimationEnabled = ValueNotifier(true);  final ValueNotifier<bool> lyricsSweepEnabled = ValueNotifier(false);

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
  }  Future<void> saveLocale(String localeString) async {
    final prefs = await _instance;
    await prefs.setString(_localeKey, localeString);
  }  Future<String?> loadLocale() async {
    final prefs = await _instance;
    return prefs.getString(_localeKey);
  }  Future<void> saveDiscordEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_discordEnabledKey, enabled);
  }

  Future<bool> loadDiscordEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_discordEnabledKey) ?? false;
  }  Future<void> saveQueueOpen(bool open) async {
    final prefs = await _instance;
    await prefs.setBool(_queueOpenKey, open);
  }

  Future<bool?> loadQueueOpen() async {
    final prefs = await _instance;
    return prefs.getBool(_queueOpenKey);
  }  Future<void> setPlayerAnimationEnabled(bool enabled) async {
    playerAnimationEnabled.value = enabled;
    final prefs = await _instance;
    await prefs.setBool(_playerAnimationKey, enabled);
  }  Future<bool> loadPlayerAnimationEnabled() async {
    final prefs = await _instance;
    final saved = prefs.getBool(_playerAnimationKey);
    final value = saved ?? true;
    playerAnimationEnabled.value = value;
    return value;
  }  Future<void> setLyricsSweepEnabled(bool enabled) async {
    lyricsSweepEnabled.value = enabled;
    final prefs = await _instance;
    await prefs.setBool(lyricsSweepKey, enabled);
  }  Future<bool> loadLyricsSweepEnabled() async {
    final prefs = await _instance;
    final saved = prefs.getBool(lyricsSweepKey);
    final value = saved ?? false;
    lyricsSweepEnabled.value = value;
    return value;
  }  static const _skipSilenceKey = 'player.skip_silence';

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
  }  // Per-track lyrics sync offsets: {trackId: milliseconds}.
  static const _lyricsOffsetsKey = 'lyrics_offsets_v1';

  Map<String, int> _decodeOffsets(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v is int ? v : 0))
          ..removeWhere((_, v) => v == 0);
      }
    } catch (_) {}
    return {};
  }  // Saves sync offset for one track. Zero removes the entry.
  Future<void> saveLyricsOffsetFor(String trackId, Duration offset) async {
    final prefs = await _instance;
    final map = _decodeOffsets(prefs.getString(_lyricsOffsetsKey));
    if (offset == Duration.zero) {
      map.remove(trackId);
    } else {
      map[trackId] = offset.inMilliseconds;
    }
    await prefs.setString(_lyricsOffsetsKey, jsonEncode(map));
  }  Future<bool> hasLyricsOffsetFor(String trackId) async {
    final prefs = await _instance;
    return _decodeOffsets(
      prefs.getString(_lyricsOffsetsKey),
    ).containsKey(trackId);
  }  Future<Duration> loadLyricsOffsetFor(String trackId) async {
    final prefs = await _instance;
    final ms = _decodeOffsets(prefs.getString(_lyricsOffsetsKey))[trackId];
    return ms != null ? Duration(milliseconds: ms) : Duration.zero;
  }  Future<void> saveShuffleEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_shuffleEnabledKey, enabled);
  }  Future<bool?> loadShuffleEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_shuffleEnabledKey);
  }  Future<void> saveRadioEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_radioEnabledKey, enabled);
  }  Future<bool?> loadRadioEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_radioEnabledKey);
  }  Future<void> saveRepeatMode(String mode) async {
    final prefs = await _instance;
    await prefs.setString(_repeatModeKey, mode);
  }  Future<String?> loadRepeatMode() async {
    final prefs = await _instance;
    return prefs.getString(_repeatModeKey);
  }  Future<void> saveQueue(List<String> ids) async {
    final prefs = await _instance;
    await prefs.setStringList(_queueKey, ids);
  }  Future<List<String>?> loadQueue() async {
    final prefs = await _instance;
    return prefs.getStringList(_queueKey);
  }  Future<void> saveOriginalQueue(List<String>? ids) async {
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
  }  Future<void> saveQueueIndex(int index) async {
    final prefs = await _instance;
    await prefs.setInt(_queueIndexKey, index);
  }

  Future<int?> loadQueueIndex() async {
    final prefs = await _instance;
    return prefs.getInt(_queueIndexKey);
  }  Future<void> saveCacheMaxSize(int? sizeMb) async {
    final prefs = await _instance;
    if (sizeMb == null) {
      await prefs.remove(_cacheMaxSizeKey);
    } else {
      await prefs.setInt(_cacheMaxSizeKey, sizeMb);
    }
  }  Future<int?> loadCacheMaxSize() async {
    final prefs = await _instance;
    return prefs.getInt(_cacheMaxSizeKey);
  }  Future<void> saveActivePlaylistId(int? id) async {
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

  /// Estilo del header del detalle de playlist (móvil): `true` = portada 1:1
  /// sobre acento plano, `false` (por defecto) = portada full-bleed con
  /// degradado.
  Future<void> saveFlatPlaylistHeader(bool flat) async {
    final prefs = await _instance;
    await prefs.setBool(_flatPlaylistHeaderKey, flat);
  }

  /// `null` si el usuario nunca cambió el estilo (por defecto: full-bleed).
  Future<bool?> loadFlatPlaylistHeader() async {
    final prefs = await _instance;
    return prefs.getBool(_flatPlaylistHeaderKey);
  }

  // Saves track id + position in a single write to avoid race conditions.
  Future<void> saveResumePosition(int seconds, String trackId) async {
    final prefs = await _instance;
    await prefs.setString(
      _resumeKey,
      jsonEncode({'trackId': trackId, 'seconds': seconds}),
    );
  }  Future<({String trackId, int seconds})?> loadResumePosition() async {
    final prefs = await _instance;
    final raw = prefs.getString(_resumeKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return (
        trackId: map['trackId'] as String,
        seconds: map['seconds'] as int,
      );    } catch (_) {
      return null;
    }
  }
}
