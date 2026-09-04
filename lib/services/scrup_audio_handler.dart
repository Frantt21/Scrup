import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;

import '../core/track.dart';
import '../core/app_log.dart';
import '../data/database.dart';
import 'player_service.dart';

/// Bridge to OS media controls via audio_service:
/// Windows (SMTC) / macOS (Now Playing) / Linux (MPRIS) / Android
/// (notificación + lock screen).
/// Created before runApp, connected via [attach].
class ScrupAudioHandler extends BaseAudioHandler with SeekHandler {
  /// Acción custom de la notificación: alternar aleatorio.
  static const String shuffleAction = 'com.scrup.action.SHUFFLE';

  /// Acción custom de la notificación: alternar favorito.
  static const String favoriteAction = 'com.scrup.action.FAVORITE';

  PlayerService? _player;
  AppDatabase? _db;
  final List<StreamSubscription> _subs = [];

  bool _hasTrack = false;
  bool _playing = false;
  bool _buffering = false;
  Duration _lastPosition = Duration.zero;
  Duration? _lastDuration;
  Track? _currentTrack;

  bool _shuffle = false;
  bool _isFavorite = false;
  int _favoritesId = -1;
  StreamSubscription<bool>? _favSub;

  // Throttle position to ~1Hz to avoid SMTC overlay jitter on Windows.
  int _lastPublishedSec = -1;

  // Connects handler to player. Idempotent (admite cablear [db] más tarde).
  void attach(PlayerService player, {AppDatabase? db}) {
    if (_player != null) {
      if (db != null && _db == null) {
        _db = db;
        unawaited(_setupFavorites());
      }
      return;
    }
    _player = player;
    _db = db;
    _shuffle = player.shuffle.value;
    player.shuffle.addListener(_onShuffleChanged);
    _subs.addAll([
      player.currentTrack.listen((track) {
        if (track == null) {
          _hasTrack = false;
          _currentTrack = null;
          _lastDuration = null;
          mediaItem.add(null);
          _watchFavorite();
          return;
        }
        _hasTrack = true;
        _currentTrack = track;
        _lastDuration = track.duration ?? _lastDuration;
        mediaItem.add(_mediaItemFor(track));
        appLog(
          'OS',
          'mediaItem id=${shortId(track.id)} dur=${track.duration ?? _lastDuration} '
          'art=${shortUrl(track.thumbnailUrl)}',
        );
        _maybeUpgradeArtwork(track);
        _watchFavorite();
        _publishPlaybackState();
      }),
      player.playing.listen((playing) {
        _playing = playing;
        _publishPlaybackState();
      }),
      // Sin processingState la sesión queda en STATE_NONE y SystemUI no
      // pinta timestamp/seekbar (el progreso necesita READY/PLAYING).
      player.buffering.listen((buffering) {
        _buffering = buffering;
        _publishPlaybackState();
      }),
      // Feed OS progress bar (throttle ~1Hz).
      player.position.listen((pos) {
        _lastPosition = pos;
        final sec = pos.inMilliseconds ~/ 1000;
        if (sec == _lastPublishedSec) return;
        _lastPublishedSec = sec;
        _publishPlaybackState();
      }),
      // La duración real llega DESPUÉS de publicar la pista (enriquecido o
      // cabecera del stream): se re-emite el MediaItem para que la
      // notificación pinte el timestamp total y la seekbar.
      player.duration.listen((d) {
        _lastDuration = d;
        final item = mediaItem.value;
        if (item != null && item.duration != d) {
          appLog('OS', 'duración viva $d → re-emit ${shortId(item.id)}');
          mediaItem.add(item.copyWith(duration: d));
        }
      }),
    ]);
    unawaited(_setupFavorites());
    // Don't publish empty state — OS overlay activates on first track.
  }

  void _onShuffleChanged() {
    final enabled = _player?.shuffle.value ?? false;
    if (enabled == _shuffle) return;
    _shuffle = enabled;
    appLog('OS', 'shuffle → $enabled');
    _publishPlaybackState();
  }

  Future<void> _setupFavorites() async {
    final db = _db;
    if (db == null) return;
    try {
      _favoritesId = await db.ensureFavoritesPlaylist();
    } catch (_) {
      return;
    }
    _watchFavorite();
  }

  void _watchFavorite() {
    unawaited(_favSub?.cancel());
    _favSub = null;
    final db = _db;
    final track = _currentTrack;
    if (db == null || track == null || _favoritesId < 0) {
      if (_isFavorite) {
        _isFavorite = false;
        _publishPlaybackState();
      }
      return;
    }
    _favSub = db.watchTrackInPlaylist(_favoritesId, track.id).listen((inside) {
      if (inside == _isFavorite) return;
      _isFavorite = inside;
      appLog('OS', 'favorito ${shortId(track.id)} → $inside');
      _publishPlaybackState();
    });
  }

  MediaItem _mediaItemFor(Track track) {
    // La notificación descarga el artUri por su cuenta. Se publica la URL
    // ORIGINAL al instante (siempre resuelve) y [_maybeUpgradeArtwork] la
    // sube a alta resolución solo si verifica 200 — `maxresdefault.jpg` no
    // existe en todos los videos y un 404 dejaría la notificación sin arte.
    final raw = track.thumbnailUrl;
    final art = (raw == null || raw.isEmpty) ? null : Uri.tryParse(raw);
    return MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUri: art,
      duration: track.duration ?? _lastDuration,
    );
  }

  /// URLs en alta resolución ya verificadas (200) o rotas (no-200).
  final Set<String> _verifiedHiRes = {};
  final Set<String> _brokenHiRes = {};
  static const int _maxArtworkProbeCache = 500;

  /// Intenta subir el arte de la notificación a alta resolución sin
  /// regresiones: verifica la variante HQ con un HEAD barato y solo la
  /// publica si responde 200 y la pista sigue siendo la actual.
  void _maybeUpgradeArtwork(Track track) {
    final raw = track.thumbnailUrl;
    if (raw == null || raw.isEmpty) return;
    final hi = Track.hiResThumbnail(raw);
    if (hi == null || hi == raw) return;
    if (_brokenHiRes.contains(hi)) return;
    if (_verifiedHiRes.contains(hi)) {
      _reemitArtwork(track.id, hi);
      return;
    }
    unawaited(_verifyHiRes(track.id, hi));
  }

  Future<void> _verifyHiRes(String trackId, String hi) async {
    try {
      final resp = await http
          .head(
            Uri.parse(hi),
            headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
          )
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        _remember(_verifiedHiRes, hi);
        _reemitArtwork(trackId, hi);
      } else {
        // 404 y demás: la variante HQ no existe para este video.
        _remember(_brokenHiRes, hi);
      }
    } catch (_) {
      // Fallo transitorio (red): no se cachea, se reintenta la próxima vez.
    }
  }

  void _remember(Set<String> set, String url) {
    set.add(url);
    while (set.length > _maxArtworkProbeCache) {
      set.remove(set.first);
    }
  }

  void _reemitArtwork(String trackId, String artUrl) {
    if (_currentTrack?.id != trackId) return;
    final item = mediaItem.value;
    if (item == null || item.id != trackId) return;
    final uri = Uri.tryParse(artUrl);
    if (uri == null || item.artUri == uri) return;
    mediaItem.add(item.copyWith(artUri: uri));
  }

  // Publishes playback state to OS. No-op if no track loaded.
  void _publishPlaybackState() {
    if (!_hasTrack) return;
    // Orden fijo: [shuffle, prev, play/pausa, next, favorito]. El nativo
    // de audio_service solo pinta acciones ESTÁNDAR en la notificación:
    // las customs (shuffle/favorito) viajan en la media session y el
    // sistema las muestra en el reproductor expandido (Android 13+).
    // nativeActions = [prev(0), play(1), next(2)] → compactas [0, 1, 2].
    final controls = [
      MediaControl.custom(
        androidIcon: _shuffle
            ? 'drawable/ic_shuffle'
            : 'drawable/ic_shuffle_off',
        label: _shuffle ? 'Desactivar aleatorio' : 'Activar aleatorio',
        name: shuffleAction,
      ),
      MediaControl.skipToPrevious,
      _playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.custom(
        androidIcon: _isFavorite
            ? 'drawable/ic_favorite'
            : 'drawable/ic_favorite_border',
        label: _isFavorite ? 'Quitar de favoritos' : 'Añadir a favoritos',
        name: favoriteAction,
      ),
    ];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {MediaAction.seek, MediaAction.setShuffleMode},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: _hasTrack && _playing,
        updatePosition: _lastPosition,
        speed: 1.0,
      ),
    );
  }

  // ------------------------------------------------------ comandos del OS

  @override
  Future<void> play() async {
    appLog('OS', 'tap play (hasTrack=$_hasTrack)');
    if (!_hasTrack) return;
    _playing = true;
    _publishPlaybackState();
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    appLog('OS', 'tap pause (hasTrack=$_hasTrack)');
    if (!_hasTrack) return;
    _playing = false;
    _publishPlaybackState();
    await _player?.pause();
  }

  @override
  Future<void> skipToNext() async {
    appLog('OS', 'tap next');
    await _player?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    appLog('OS', 'tap prev');
    await _player?.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    appLog('OS', 'seek $position');
    _lastPosition = position;
    // Force next position event past the throttle.
    _lastPublishedSec = -1;
    await _player?.seek(position);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    appLog('OS', 'system shuffleMode=$shuffleMode');
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    if (enabled != _shuffle) {
      _player?.toggleShuffle();
    }
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) {
    appLog('OS', 'customAction $name');
    switch (name) {
      case shuffleAction:
        _player?.toggleShuffle();
        return Future.value();
      case favoriteAction:
        return _toggleFavorite();
      default:
        return super.customAction(name, extras);
    }
  }

  Future<void> _toggleFavorite() async {
    final db = _db;
    final track = _currentTrack;
    if (db == null || track == null || _favoritesId < 0) return;
    try {
      if (_isFavorite) {
        await db.removeFromPlaylist(_favoritesId, track.id);
      } else {
        await db.addToPlaylist(_favoritesId, track);
      }
    } catch (_) {
      // El watch de favoritos republica el estado al cambiar.
    }
  }

  @override
  Future<void> stop() async {
    // Publish paused state before clearing track (guard needs _hasTrack).
    _playing = false;
    _publishPlaybackState();
    _hasTrack = false;
    mediaItem.add(null);
    // Pause instead of stop: stop() triggers 'completed' event → auto-advance.
    await _player?.pause();
  }

  Future<void> dispose() async {
    _player?.shuffle.removeListener(_onShuffleChanged);
    await _favSub?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
