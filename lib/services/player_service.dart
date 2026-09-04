import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

import '../core/queue_shuffle.dart';
import '../core/track.dart';
import '../core/app_log.dart';
import 'audio_backend.dart';

/// Loop modes (own enum to avoid clash with Flutter's RepeatMode).
enum LoopMode { off, all, one }

/// Audio source resolved for a track: stream URL or local cached file.
class PlayableSource {
  final String uri;
  final bool isLocal;
  const PlayableSource(this.uri, {this.isLocal = false});
}

/// Snapshot of the queue for session persistence.
class QueuePersistenceSnapshot {
  final List<String> trackIds;
  final List<String>? originalTrackIds;
  final int index;
  final int? playlistId;

  const QueuePersistenceSnapshot({
    required this.trackIds,
    this.originalTrackIds,
    required this.index,
    this.playlistId,
  });
}

/// Audio player with queue, shuffle, repeat, radio and local caching.
class PlayerService {
  final AudioBackend _player;
  final math.Random _random = math.Random();

  final Future<PlayableSource> Function(Track track) resolveSource;

  final Future<void> Function(Track track)? preload;

  final Future<List<Track>> Function(Track track)? recommend;
  final Future<Track?> Function(Track track)? enrich;
  final Future<void> Function(Track track)? onPlayed;
  final Future<void> Function(Track track)? onEnriched;

  final Future<void> Function(bool enabled)? onShuffleChanged;
  final Future<void> Function(bool enabled)? onRadioChanged;
  final Future<void> Function(LoopMode mode)? onRepeatChanged;
  final Future<void> Function(QueuePersistenceSnapshot snapshot)?
  onQueueChanged;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _trackController = StreamController<Track?>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<Duration> get position => _positionController.stream;
  Stream<Duration?> get duration => _durationController.stream;
  Stream<bool> get playing => _playingController.stream;
  Stream<bool> get buffering => _bufferingController.stream;
  Stream<Track?> get currentTrack => _trackController.stream;
  Stream<String> get errors => _errorController.stream;

  Track? get currentTrackValue => _currentTrack;
  Duration? get durationValue => _lastDuration;
  Duration get positionValue => _lastPosition;

  final ValueNotifier<String?> preparingTrackId = ValueNotifier<String?>(null);
  final ValueNotifier<LoopMode> repeatMode = ValueNotifier<LoopMode>(
    LoopMode.off,
  );
  final ValueNotifier<bool> shuffle = ValueNotifier<bool>(false);
  final ValueNotifier<bool> radio = ValueNotifier<bool>(true);
  final ValueNotifier<int?> activePlaylistId = ValueNotifier<int?>(null);
  final ValueNotifier<double> volume = ValueNotifier<double>(1.0);
  final ValueNotifier<AudioDevice> audioDevice = ValueNotifier<AudioDevice>(
    AudioDevice.auto(),
  );
  final ValueNotifier<List<AudioDevice>> audioDevices =
      ValueNotifier<List<AudioDevice>>(const []);

  bool _playing = false;
  Duration _lastPosition = Duration.zero;
  Track? _currentTrack;
  Duration? _lastDuration;

  // Throttle position stream to ~4fps; zero emits instantly.
  static const _positionEmitInterval = Duration(milliseconds: 250);
  DateTime? _lastPositionEmit;

  // Timestamp of last open(): media_kit emits spurious completed on open,
  // discard if it fires within 3s.
  DateTime _openedAt = DateTime.now();
  bool _lastSourceIsLocal = true;

  // EXPERIMENTO kNoAudioMount: ticker que simula la reproducción (posición
  // avanzando) sin montar el stream de audio.
  Timer? _fakeTimer;

  // Discards stale responses when switching tracks fast.
  int _playToken = 0;
  final Map<String, int> _prematureRetries = {};

  /// Cola de reproducción (solo reproducción individual si está vacía).
  final List<Track> _queue = [];
  int _queueIndex = -1;

  // Original queue order before shuffle (restored on shuffle off).
  List<Track>? _originalQueue;

  final ValueNotifier<List<Track>> queue = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<int> queueIndex = ValueNotifier<int>(-1);

  // Publishes queue state to UI and persists snapshot (best-effort).
  void _notifyQueueChanged() {
    queue.value = List.unmodifiable(_queue);
    queueIndex.value = _queueIndex;
    final cb = onQueueChanged;
    if (cb != null) unawaited(_notifyQueuePersist(cb, _queueSnapshot()));
  }

  QueuePersistenceSnapshot _queueSnapshot() {
    return QueuePersistenceSnapshot(
      trackIds: _queue.map((t) => t.id).toList(),
      originalTrackIds: _originalQueue?.map((t) => t.id).toList(),
      index: _queueIndex,
      playlistId: activePlaylistId.value,
    );
  }

  QueuePersistenceSnapshot get queueSnapshot => _queueSnapshot();

  Future<void> _notifyQueuePersist(
    Future<void> Function(QueuePersistenceSnapshot) cb,
    QueuePersistenceSnapshot snapshot,
  ) async {
    try {
      await cb(snapshot);
    } catch (_) {}
  }

  double _lastVolumeBeforeMute = 1.0;

  PlayerService({
    required AudioBackend audioBackend,
    required this.resolveSource,
    this.recommend,
    this.enrich,
    this.preload,
    this.onPlayed,
    this.onEnriched,
    this.onShuffleChanged,
    this.onRadioChanged,
    this.onRepeatChanged,
    this.onQueueChanged,
  }) : _player = audioBackend {
    _player.positionStream.listen((p) {
      _lastPosition = p;
      // Throttle: emit at most every ~250ms, but zero always emits instantly.
      final now = DateTime.now();
      if (p == Duration.zero ||
          _lastPositionEmit == null ||
          now.difference(_lastPositionEmit!) >= _positionEmitInterval) {
        _lastPositionEmit = now;
        _positionController.add(p);
      }
    });
    _player.durationStream.listen((d) {
      _lastDuration = d;
      _durationController.add(d);
    });
    _player.playingStream.listen((p) {
      _playing = p;
      _playingController.add(p);
    });
    // Estado ACTUAL del backend: los streams solo emiten cambios y si el
    // arranque de la reproducción ocurrió antes de suscribirnos (p. ej.
    // audio_service restaurando el estado al iniciar), `_playing` quedaría
    // desincronizado y el toggle play/pausa rompería (siempre llamaría a
    // play(), que es no-op cuando ya suena).
    _playing = _player.isPlaying;
    _player.bufferingStream.listen(_bufferingController.add);
    _player.volumeStream.listen((v) {
      // Backends emiten NORMALIZADO 0..1.
      volume.value = v.clamp(0.0, 1.0);
    });
    _player.errorStream.listen(_errorController.add);
    _player.completedStream.listen((_) => _onTrackCompleted());
    _player.audioDevice.addListener(_syncAudioDevice);
    _player.audioDevices.addListener(_syncAudioDevices);
    // Initialize with current state
    audioDevice.value = _player.audioDevice.value;
    audioDevices.value = _player.audioDevices.value;
  }

  void _syncAudioDevice() => audioDevice.value = _player.audioDevice.value;

  void _syncAudioDevices() => audioDevices.value = _player.audioDevices.value;

  bool get isPlaying => _playing;

  // ── Control ──────────────────────────────────────────────────────────
  Future<bool> playTrack(Track track) async {
    activePlaylistId.value = null;
    _queue.clear();
    _queueIndex = -1;
    _originalQueue = null;
    _prematureRetries.clear();
    _notifyQueueChanged();
    return _openAndPlay(track);
  }

  Future<bool> restoreLastTrack(Track track, {int positionSeconds = 0}) async {
    final token = ++_playToken;

    activePlaylistId.value = null;
    _queue.clear();
    _queueIndex = -1;
    _originalQueue = null;
    _prematureRetries.clear();
    _notifyQueueChanged();
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    return _openPaused(track, token, positionSeconds: positionSeconds);
  }

  Future<bool> restoreQueue(
    List<Track> tracks, {
    int startIndex = 0,
    int? playlistId,
    List<String>? originalTrackIds,
    int positionSeconds = 0,
  }) async {
    if (tracks.isEmpty) return false;
    final token = ++_playToken;
    startIndex = startIndex.clamp(0, tracks.length - 1);
    activePlaylistId.value = playlistId;
    _queue
      ..clear()
      ..addAll(tracks);
    _queueIndex = startIndex;
    // Restore pre-shuffle order if shuffle is still active.
    if (originalTrackIds != null && shuffle.value) {
      final byId = {for (final t in _queue) t.id: t};
      final originalTracks = <Track>[];
      for (final id in originalTrackIds) {
        final t = byId[id];
        if (t != null) originalTracks.add(t);
      }
      _originalQueue = originalTracks.length > 1 ? originalTracks : null;
    } else {
      _originalQueue = null;
    }
    _prematureRetries.clear();
    _notifyQueueChanged();
    final track = _queue[startIndex];
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    return _openPaused(track, token, positionSeconds: positionSeconds);
  }

  // Opens track paused for session restore.
  Future<bool> _openPaused(
    Track track,
    int token, {
    int positionSeconds = 0,
  }) async {
    try {
      await _player.pause();
      final src = await resolveSource(track);
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      // Mark before open (spurious completed fires within 3s).
      _openedAt = DateTime.now();
      if (kNoAudioMount) {
        // EXPERIMENTO kNoAudioMount: no se monta el stream; solo se
        // publica la pista (artwork/acento/letras cargan) en pausa.
        _publishTrack(track);
        return true;
      }
      // play:false is required: open() defaults to play:true.
      await _player.open(_mediaUri(src), play: false);
      if (token != _playToken) return false;
      // Seek to saved position (libmpv clamps if track is shorter).
      if (positionSeconds > 0) {
        try {
          await _player.seek(Duration(seconds: positionSeconds));
        } catch (_) {
          // Silencioso: un fallo de seek deja la pista desde el inicio.
        }
      }

      _publishTrack(track);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
    }
  }

  Future<void> playQueue(
    List<Track> tracks, {
    int startIndex = 0,
    int? playlistId,
  }) async {
    if (tracks.isEmpty) return;
    activePlaylistId.value = playlistId;
    _queue
      ..clear()
      ..addAll(tracks);
    _prematureRetries.clear();
    var playIndex = startIndex;
    if (shuffle.value) {
      _originalQueue = List.of(_queue);
      if (_queue.length > 1) {
        playIndex = promoteThenShuffle(_queue, playIndex, _random);
      }
    }
    _notifyQueueChanged();
    await _playAt(playIndex);
  }

  Future<void> playQueueAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _playAt(index);
  }

  Future<void> next() async {
    if (!_beginSkip()) return;
    final hasNext = _queueIndex >= 0 && _queueIndex < _queue.length - 1;
    if (hasNext) {
      await _playAt(_nextIndex());
      return;
    }

    if (_queue.isNotEmpty && repeatMode.value == LoopMode.all) {
      await _playAt(0);
      return;
    }

    if (radio.value && recommend != null) {
      final current = _currentTrack;
      if (current != null) {
        await _playRadio(current);
      }
    }
  }

  Future<void> previous() async {
    if (!_beginSkip()) return;
    if (_lastPosition > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_queueIndex > 0) {
      await _playAt(_queueIndex - 1);
      return;
    }

    await seek(Duration.zero);
  }

  // Anti-spam de next/prev: los toques (botones, notificación, teclado)
  // que caen dentro de la ventana se ignoran; cada cambio aceptado ya pone
  // en marcha pipeline async que se solaparía y multiplicaría el trabajo.
  DateTime? _lastSkipAt;
  static const Duration kSkipDebounce = Duration(milliseconds: 250);

  bool _beginSkip() {
    final now = DateTime.now();
    final last = _lastSkipAt;
    if (last != null && now.difference(last) < kSkipDebounce) {
      appLog('TRACK', 'skip ignorado (debounce)');
      return false;
    }
    _lastSkipAt = now;
    return true;
  }

  Future<void> togglePlayPause() {
    if (kNoAudioMount) {
      if (_playing) {
        _stopFakePlayback();
      } else {
        _startFakePlayback(_currentTrack);
      }
      return Future.value();
    }
    // Consulta el estado REAL del backend (no el caché de `_playing`): los
    // streams solo emiten cambios y se pueden perder arranques externos
    // (audio_service restaura "playing" al iniciar).
    return _player.isPlaying ? _player.pause() : _player.play();
  }

  Future<void> play() {
    if (kNoAudioMount) {
      _startFakePlayback(_currentTrack);
      return Future.value();
    }
    return _player.play();
  }

  Future<void> pause() {
    if (kNoAudioMount) {
      _stopFakePlayback();
      return Future.value();
    }
    return _player.pause();
  }

  Future<void> seek(Duration position) {
    if (kNoAudioMount) {
      _lastPosition = position;
      _positionController.add(position);
      return Future.value();
    }
    return _player.seek(position);
  }

  Future<void> setVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    volume.value = clamped;
    await _player.setVolume(clamped);
  }

  Future<void> setAudioDevice(AudioDevice device) async {
    await _player.setAudioDevice(device);
    audioDevice.value = device;
  }

  Future<void> toggleMute() async {
    if (volume.value > 0) {
      _lastVolumeBeforeMute = volume.value;
      await setVolume(0);
    } else {
      await setVolume(_lastVolumeBeforeMute > 0 ? _lastVolumeBeforeMute : 0.5);
    }
  }

  Future<void> stop() {
    if (kNoAudioMount) {
      _stopFakePlayback();
      return Future.value();
    }
    return _player.stop();
  }

  // Cycles repeat: off → all → one → off.
  void toggleRepeat() {
    repeatMode.value = switch (repeatMode.value) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    unawaited(_notifyRepeatChanged(repeatMode.value));
  }

  Future<void> _notifyRepeatChanged(LoopMode mode) async {
    final cb = onRepeatChanged;
    if (cb == null) return;
    try {
      await cb(mode);
    } catch (_) {}
  }

  // Toggles shuffle on/off, saving/restoring original order.
  void toggleShuffle() {
    shuffle.value = !shuffle.value;
    if (shuffle.value) {
      _applyShuffleToQueue();
    } else {
      _restoreQueueOrder();
    }
    unawaited(_notifyShuffleChanged(shuffle.value));
  }

  Future<void> _notifyShuffleChanged(bool enabled) async {
    final cb = onShuffleChanged;
    if (cb == null) return;
    try {
      await cb(enabled);
    } catch (_) {}
  }

  void _applyShuffleToQueue() {
    if (_queue.length <= 1) return;
    _originalQueue = List.of(_queue);
    final current = _queueIndex >= 0 && _queueIndex < _queue.length
        ? _queue[_queueIndex]
        : null;
    _queueIndex = shuffleKeepingCurrent(_queue, current, _random);
    _notifyQueueChanged();
  }

  void _restoreQueueOrder() {
    final saved = _originalQueue;
    _originalQueue = null;
    if (saved == null) return;
    final current = _queueIndex >= 0 && _queueIndex < _queue.length
        ? _queue[_queueIndex]
        : null;
    final (restored, index) = restoreQueueOrder(_queue, saved, current);
    _queue
      ..clear()
      ..addAll(restored);
    _queueIndex = index;
    _notifyQueueChanged();
  }

  // Adds track to queue. Random position if shuffle is active.
  bool addToQueue(Track track) {
    if (_queue.isEmpty) return false;
    final insertAt = shuffle.value && _queueIndex >= 0
        ? _queueIndex + 1 + _random.nextInt(_queue.length - _queueIndex)
        : _queue.length;
    _queue.insert(insertAt, track);
    _notifyQueueChanged();
    _schedulePreloads();
    return true;
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length)
      return;

    final moved = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, moved);

    // Update current track index if it was moved.
    if (_queueIndex == oldIndex) {
      _queueIndex = newIndex;
    } else if (oldIndex < _queueIndex && newIndex >= _queueIndex) {
      _queueIndex--;
    } else if (oldIndex > _queueIndex && newIndex <= _queueIndex) {
      _queueIndex++;
    }

    // Sync original queue order if shuffle is active.
    if (_originalQueue != null) {
      final origMoved = _originalQueue!.removeAt(oldIndex);
      _originalQueue!.insert(newIndex, origMoved);
    }

    _notifyQueueChanged();
    _schedulePreloads();
  }

  void toggleRadio() {
    radio.value = !radio.value;
    unawaited(_notifyRadioChanged(radio.value));
  }

  Future<void> _notifyRadioChanged(bool enabled) async {
    final cb = onRadioChanged;
    if (cb == null) return;
    try {
      await cb(enabled);
    } catch (_) {}
  }

  // ── Internal ─────────────────────────────────────────────────────────
  Future<void> _onTrackCompleted() async {
    final token = _playToken;
    final current = _currentTrack;

    // media_kit emits spurious completed on open/replace — discard if <3s.
    // Remote streams that die within 8s are treated as premature cuts.
    final sinceOpened = DateTime.now().difference(_openedAt);
    final streamCut =
        !_lastSourceIsLocal &&
        current != null &&
        _lastPosition > Duration.zero &&
        _lastPosition < const Duration(seconds: 8) &&
        (_prematureRetries[current.id] ?? 0) < 1;

    if (sinceOpened < const Duration(seconds: 3)) {
      if (streamCut) {
        await _retryPrematureCut(current);
      }
      return;
    }

    if (streamCut) {
      await _retryPrematureCut(current);
      return;
    }

    // Repeat one: replay current track.
    if (repeatMode.value == LoopMode.one && current != null) {
      if (_queueIndex >= 0) {
        await _playAt(_queueIndex);
      } else {
        await _openAndPlay(current);
      }
      return;
    }

    // Next in queue.
    if (_queueIndex >= 0 && _queueIndex < _queue.length - 1) {
      await _playAt(_nextIndex());
      return;
    }

    // Queue exhausted + repeat all: back to start.
    if (_queue.isNotEmpty && repeatMode.value == LoopMode.all) {
      await _playAt(0);
      return;
    }

    // Radio: find more from the same artist.
    if (radio.value && recommend != null && token == _playToken) {
      final base = _currentTrack;
      if (base != null) {
        await _playRadio(base);
      }
    }
  }

  Future<void> _retryPrematureCut(Track current) async {
    _prematureRetries[current.id] = (_prematureRetries[current.id] ?? 0) + 1;
    _errorController.add(
      'La reproducción de "${current.title}" se interrumpió; '
      'reintentando…',
    );
    if (_queueIndex >= 0) {
      await _playAt(_queueIndex);
    } else {
      await _openAndPlay(current);
    }
  }

  // Cuántas pistas siguientes se precargan. Las primeras 2 arrancan de
  // inmediato; el propio servicio de caché limita la concurrencia
  // ([AudioCacheService.maxConcurrentPreloads] = 2) y encola el resto en
  // orden, así las 3-5 nunca compiten por ancho de banda con las 2
  // prioritarias.
  static const int _preloadAhead = 5;

  // Preloads the next N tracks in the queue (background, best-effort).
  void _schedulePreloads() {
    final fn = preload;
    if (fn == null || _queueIndex < 0 || _queue.isEmpty) return;
    final targets = <Track>[];
    for (var i = 1; i <= _preloadAhead; i++) {
      final idx = _queueIndex + i;
      if (idx >= _queue.length) break;
      targets.add(_queue[idx]);
    }
    appLog('PERF', 'preload x${targets.length} desde idx=$_queueIndex');
    for (final t in targets) {
      unawaited(_preloadTrack(fn, t));
    }
  }

  Future<void> _preloadTrack(
    Future<void> Function(Track) fn,
    Track track,
  ) async {
    try {
      await fn(track);
    } catch (_) {}
  }

  int _nextIndex() => _queueIndex + 1;

  // Enqueues songs from the same artist (radio mode).
  Future<void> _playRadio(Track base) async {
    try {
      final tracks = await recommend!(base);
      if (tracks.isEmpty) return;
      final known = _queue.map((t) => t.id).toSet()..add(base.id);
      final fresh = tracks.where((t) => !known.contains(t.id)).toList();
      if (fresh.isEmpty) return;
      if (shuffle.value) fresh.shuffle(_random);
      _queue.addAll(fresh);
      _notifyQueueChanged();
      await _playAt(_queue.length - fresh.length);
    } catch (e) {
      _errorController.add('No se pudo recomendar música: $e');
    }
  }

  // Plays track at index in queue. Falls back to next on failure.
  Future<bool> _playAt(int index) async {
    if (index < 0 || index >= _queue.length) return false;
    final token = ++_playToken;
    _queueIndex = index;
    _notifyQueueChanged();
    final track = _queue[index];
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    final sw = Stopwatch()..start();
    void lap(String what) =>
        appLog('PERF', 'playAt $what +${sw.elapsedMilliseconds}ms id=${track.id}');
    appLog('TRACK', 'preparing id=${track.id} idx=$index');
    try {
      // Resolve source + enrich in parallel; play immediately, enrich later.
      // Sin `pause()` previa: el guard de `_openedAt` (completed espurio en
      // <3s) ya lo cubre, y quitar el round-trip nativo hace el montaje más
      // ligero. `open()` ya reproduce por defecto (play:true): sin `play()`
      // extra (otro round-trip nativo de sobra).
      final srcFuture = resolveSource(track);
      final enrichFuture = _enrich(track);
      final src = await srcFuture;
      lap('source ok local=${src.isLocal}');
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      _openedAt = DateTime.now();
      if (kNoAudioMount) {
        // EXPERIMENTO kNoAudioMount: sin open/play (no se monta el audio).
        // El resto del pipeline corre: publish → artwork/acento/letras.
        // La reproducción se simula con un ticker de posición.
        _startFakePlayback(track);
      } else {
        await _player.open(_mediaUri(src));
        lap('opened');
      }
      _publishTrack(track);
      appLog('TRACK', 'published id=${track.id} dur=${track.duration}');
      unawaited(_notifyPlayed(track));
      unawaited(_enrichThenApply(track, enrichFuture, token));
      _schedulePreloads();
      return true;
    } catch (e) {
      _errorController.add('No se pudo reproducir "${track.title}": $e');
      if (_queueIndex < _queue.length - 1) {
        return _playAt(_queueIndex + 1);
      }
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
    }
  }

  // Opens and plays a standalone track (outside queue).
  Future<bool> _openAndPlay(Track track) async {
    final token = ++_playToken;
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    try {
      final srcFuture = resolveSource(track);
      final enrichFuture = _enrich(track);
      final src = await srcFuture;
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      _openedAt = DateTime.now();
      if (kNoAudioMount) {
        // EXPERIMENTO kNoAudioMount: sin open/play.
        _startFakePlayback(track);
      } else {
        await _player.open(_mediaUri(src));
      }
      _publishTrack(track);
      unawaited(_notifyPlayed(track));
      unawaited(_enrichThenApply(track, enrichFuture, token));
      return true;
    } catch (e) {
      _errorController.add('No se pudo reproducir "${track.title}": $e');
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
    }
  }

  Future<Track?> _enrich(Track track) async {
    final fn = enrich;
    if (fn == null) return null;
    try {
      return await fn(track);
    } catch (_) {
      return null;
    }
  }

  // EXPERIMENTO kNoAudioMount: arranca/para la reproducción simulada.
  void _startFakePlayback(Track? track) {
    _fakeTimer?.cancel();
    _playing = true;
    _playingController.add(true);
    final dur = track?.duration;
    if (dur != null && dur > Duration.zero) {
      _lastDuration = dur;
      _durationController.add(dur);
    }
    _fakeTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final next = _lastPosition + const Duration(milliseconds: 500);
      final d = _lastDuration;
      _lastPosition = (d != null && d > Duration.zero && next >= d) ? d : next;
      _positionController.add(_lastPosition);
    });
  }

  void _stopFakePlayback() {
    _fakeTimer?.cancel();
    _fakeTimer = null;
    _playing = false;
    _playingController.add(false);
  }

  // Resets playback state to blank while loading a new track.
  void _clearPlaybackState() {
    _fakeTimer?.cancel();
    _fakeTimer = null;
    _lastPosition = Duration.zero;
    _currentTrack = null;
    _trackController.add(null);
    _positionController.add(Duration.zero);
    _durationController.add(null);
    _playing = false;
    _playingController.add(false);
    _bufferingController.add(false);
  }

  void _publishTrack(Track track) {
    _currentTrack = track;
    _trackController.add(track);
  }

  // Updates metadata after manual edit, without touching playback.
  Future<void> updateCurrentMetadata(Track updated) async {
    final i = _queue.indexWhere((t) => t.id == updated.id);
    final isCurrent = _currentTrack?.id == updated.id;
    if (i < 0 && !isCurrent) return;
    if (i >= 0) {
      _queue[i] = updated;
      _notifyQueueChanged();
    }
    if (isCurrent) {
      _publishTrack(updated);
    }
    final cb = onEnriched;
    if (cb != null) {
      try {
        await cb(updated);
      } catch (_) {}
    }
  }

  // Applies Deezer enrichment in background. Skips if track changed.
  Future<void> _enrichThenApply(
    Track original,
    Future<Track?> enrichFuture,
    int token,
  ) async {
    final enriched = await enrichFuture;
    if (token != _playToken) return;
    if (enriched == null || enriched.id != original.id) return;
    appLog(
      'TRACK',
      'enriched id=${enriched.id} dur=${enriched.duration} '
      'art=${enriched.thumbnailUrl != original.thumbnailUrl ? 'NEW' : 'same'}',
    );
    _publishTrack(enriched);
    final cb = onEnriched;
    if (cb != null) {
      try {
        await cb(enriched);
      } catch (_) {}
    }
  }

  Future<void> _notifyPlayed(Track track) async {
    final cb = onPlayed;
    if (cb == null) return;
    try {
      await cb(track);
    } catch (_) {}
  }

  static String _mediaUri(PlayableSource src) {
    if (!src.isLocal) return src.uri;
    return Uri.file(src.uri).toString();
  }

  Future<void> dispose() async {
    _fakeTimer?.cancel();
    _fakeTimer = null;
    _player.audioDevice.removeListener(_syncAudioDevice);
    _player.audioDevices.removeListener(_syncAudioDevices);
    await _player.dispose();
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _trackController.close();
    await _errorController.close();
    preparingTrackId.dispose();
    repeatMode.dispose();
    shuffle.dispose();
    radio.dispose();
    activePlaylistId.dispose();
    volume.dispose();
    audioDevice.dispose();
    audioDevices.dispose();
    queue.dispose();
    queueIndex.dispose();
  }
}
