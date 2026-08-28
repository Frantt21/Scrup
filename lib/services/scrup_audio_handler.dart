import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../core/track.dart';
import 'player_service.dart';

/// Bridge to OS media controls via audio_service:
/// Windows (SMTC) / macOS (Now Playing) / Linux (MPRIS).
/// Created before runApp, connected via [attach].
class ScrupAudioHandler extends BaseAudioHandler with SeekHandler {
  PlayerService? _player;
  final List<StreamSubscription> _subs = [];

  bool _hasTrack = false;
  bool _playing = false;
  Duration _lastPosition = Duration.zero;

  // Throttle position to ~1Hz to avoid SMTC overlay jitter on Windows.
  int _lastPublishedSec = -1;

  // Connects handler to player. Idempotent.
  void attach(PlayerService player) {
    if (_player != null) return;
    _player = player;
    _subs.addAll([
      player.currentTrack.listen((track) {
        if (track == null) {
          _hasTrack = false;
          mediaItem.add(null);
          return;
        }
        _hasTrack = true;
        mediaItem.add(_mediaItemFor(track));
        _publishPlaybackState();
      }),
      player.playing.listen((playing) {
        _playing = playing;
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
    ]);
    // Don't publish empty state — OS overlay activates on first track.
  }

  MediaItem _mediaItemFor(Track track) {
    return MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUri: track.thumbnailUrl != null
          ? Uri.tryParse(track.thumbnailUrl!)
          : null,
      duration: track.duration,
    );
  }

  // Publishes playback state to OS. No-op if no track loaded.
  void _publishPlaybackState() {
    if (!_hasTrack) return;
    final controls = [
      MediaControl.skipToPrevious,
      _playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {MediaAction.seek},
        playing: _hasTrack && _playing,
        updatePosition: _lastPosition,
        speed: 1.0,
      ),
    );
  }

  // ------------------------------------------------------ comandos del OS

  @override
  Future<void> play() async {
    if (!_hasTrack) return;
    _playing = true;
    _publishPlaybackState();
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    if (!_hasTrack) return;
    _playing = false;
    _publishPlaybackState();
    await _player?.pause();
  }

  @override
  Future<void> skipToNext() async {
    await _player?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await _player?.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    _lastPosition = position;
    // Force next position event past the throttle.
    _lastPublishedSec = -1;
    await _player?.seek(position);
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
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
