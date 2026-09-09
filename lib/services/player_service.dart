import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

import '../core/queue_shuffle.dart';
import '../core/track.dart';
import '../core/app_log.dart';
import 'audio_backend.dart';
import 'crossfade_backend.dart';

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

  /// Precache por disco: "despierta" page cache de las próximas pistas que ya están en disco ([AudioCacheService.warmUpcoming] lee los primeros bytes en un isolate para que el backend las tenga calientes al montar la pista). `null` donde no aplica; las que no están en disco las cubre [preload].
  final void Function(List<String> trackIds)? prepareCached;

  final Future<List<Track>> Function(Track track)? recommend;
  final Future<Track?> Function(Track track)? enrich;
  final Future<void> Function(Track track)? onPlayed;
  final Future<void> Function(Track track)? onEnriched;

  /// Callback de persistencia del crossfade: llega al SettingsStore desde
  /// main.dart para no acoplar el servicio al almacenamiento.
  final Future<void> Function(double seconds)? onCrossfadeChanged;

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

  /// Pista en preparación (objeto completo). Los widgets sin acceso a la cola (p. ej. reproducción individual de búsqueda, donde la cola se limpia antes) la usan para adelantar acento/artwork sin buscar en `queue`. Se sincroniza con [preparingTrackId] vía [_setPreparing].
  final ValueNotifier<Track?> preparingTrack = ValueNotifier<Track?>(null);
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
    required this.prepareCached,
    this.recommend,
    this.enrich,
    this.preload,
    this.onPlayed,
    this.onEnriched,
    this.onCrossfadeChanged,
    this.onShuffleChanged,
    this.onRadioChanged,
    this.onRepeatChanged,
    this.onQueueChanged,
  }) : _player = audioBackend {
    _player.positionStream.listen((p) {
      _lastPosition = p;
      final now = DateTime.now();
      if (p == Duration.zero ||
          _lastPositionEmit == null ||
          now.difference(_lastPositionEmit!) >= _positionEmitInterval) {
        _lastPositionEmit = now;
        _positionController.add(p);
      }
      _checkCrossfadeWindow(p);
    });
    _player.durationStream.listen((d) {
      _lastDuration = d;
      _durationController.add(d);
    });
    _player.playingStream.listen((p) {
      _playing = p;
      _playingController.add(p);
    });
    // Estado actual del backend: los streams solo emiten cambios y si la reproducción arrancó antes de suscribirnos (audio_service restaurando estado en init), `_playing` quedaría desincronizado y el toggle rompería (siempre llamaría play(), no-op cuando ya suena).
    _playing = _player.isPlaying;
    _player.bufferingStream.listen(_bufferingController.add);
    _player.volumeStream.listen((v) {
      volume.value = v.clamp(0.0, 1.0);
    });
    _player.errorStream.listen(_errorController.add);
    _player.completedStream.listen((_) => _onTrackCompleted());
    _player.audioDevice.addListener(_syncAudioDevice);
    _player.audioDevices.addListener(_syncAudioDevices);
    audioDevice.value = _player.audioDevice.value;
    audioDevices.value = _player.audioDevices.value;
  }

  void _syncAudioDevice() => audioDevice.value = _player.audioDevice.value;
  void _syncAudioDevices() => audioDevices.value = _player.audioDevices.value;

  bool get isPlaying => _playing;

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
    _setPreparing(track);
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
    _setPreparing(track);
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
      if (token == _playToken) _setPreparing(null);
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
      _registerSlide(1);
      await _playAt(_nextIndex(), userSkip: true);
      return;
    }

    if (_queue.isNotEmpty && repeatMode.value == LoopMode.all) {
      _registerSlide(1);
      await _playAt(0, userSkip: true);
      return;
    }

    if (radio.value && recommend != null) {
      final current = _currentTrack;
      if (current != null) {
        // El cambio (quizá asíncrono, vía radio) lo pidió el botón next.
        _registerSlide(1);
        await _playRadio(current);
      }
    }
    // Sin cambio real: no se registra intención (evita slides "fantasma" sobre cambios automáticos posteriores).
  }

  Future<void> previous() async {
    if (!_beginSkip()) return;
    if (_lastPosition > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_queueIndex > 0) {
      _registerSlide(-1);
      await _playAt(_queueIndex - 1, userSkip: true);
      return;
    }

    await seek(Duration.zero);
  }

  // Dirección del slide del artículo: la animación de cambio la pide la ACCIÓN del usuario (botones del mini/player expandido, gesto sobre el arte, teclas/notificación del OS), no la posición en la cola ni cambios automáticos (fin de pista, radio, selección en cola → fundido). `next()`/`previous()` la registran antes de cambiar; [takeSlideDirection] la consume una vez en el overlay del artwork.
  final ValueNotifier<double> _slideIntent = ValueNotifier<double>(0);
  DateTime? _slideIntentAt;

  static const Duration _slideIntentMaxAge = Duration(milliseconds: 1500);

  /// Peticiones de cambio animado iniciadas por el USUARIO (botones del player/mini, teclas y notificación del OS): +1 siguiente, −1 anterior. El overlay del artwork las escucha para reproducir el mismo carrusel que el arrastre (arte saliente + entrante) en vez del slide del switcher. `sync: true` para que el overlay capture el arte visible ANTES de que `next()`/`previous()` muevan preparing/publish.
  final StreamController<double> _slideRequests =
      StreamController<double>.broadcast(sync: true);

  Stream<double> get slideRequests => _slideRequests.stream;

  void _registerSlide(double dir) {
    _slideIntent.value = dir;
    _slideIntentAt = DateTime.now();
    _slideRequests.add(dir);
  }

  /// Devuelve (y resetea) la dirección pedida por el usuario si es reciente
  /// (+1 siguiente desde la derecha, -1 anterior desde la izquierda). Si la
  /// petición es vieja (no hubo cambio de pista) o no existe, devuelve 0
  /// (fundido).
  double takeSlideDirection() {
    final at = _slideIntentAt;
    final fresh =
        at != null &&
        DateTime.now().difference(at) < _slideIntentMaxAge;
    final v = _slideIntent.value;
    _slideIntent.value = 0;
    _slideIntentAt = null;
    return fresh ? v : 0;
  }

  /// Anti-spam de next/prev: los toques (botones, notificación, teclado) dentro de la ventana se ignoran; cada cambio aceptado arranca un pipeline async que si no se protege se solaparía y multiplicaría el trabajo.
  DateTime? _lastSkipAt;
  static const Duration kSkipDebounce = Duration(milliseconds: 250);

  /// Rate-limit de cambios de pista: mínimo entre dos _playAt reales. RECHAZA en el acto (sin esperar): antes el rechazo dejaba la acción en espera y luego la ejecutaba — 3 taps rápidos = 3 cambios acumulados. Ahora el 2º/3º tap en la ventana se descarta; el auto-advance usa un timer trailing ([_scheduleAutoAdvance]) para no quedar sin reproducir.
  static const Duration kMinTrackInterval = Duration(milliseconds: 320);

  DateTime _lastPlayAt = DateTime(0);
  /// Auto-advance diferido cuando el cambio cayó en la ventana de rate-limit (una sola timer: se reemplaza, nunca se acumula).
  Timer? _autoAdvanceTimer;

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
  // ── Crossfade ──────────────────────────────────────────────────────────

  /// Segundos de crossfade (0 = desactivado). Lo ajusta Settings (slider).
  /// Activado solo si el backend es [CrossfadeBackend].
  double _crossfadeSeconds = 0;

  /// true mientras el auto-advance de fin de pista lo gestiona el crossfade
  /// (el `completed` de la pista saliente se IGNORA para no doble-avanzar).
  bool _crossfading = false;

  /// Configura el crossfade (llamado por Settings vía main.dart).
  Future<void> setCrossfade(double seconds) async {
    _crossfadeSeconds = seconds.clamp(0.0, 12.0);
    final cb = onCrossfadeChanged;
    if (cb != null) {
      try {
        await cb(_crossfadeSeconds);
      } catch (_) {}
    }
  }

  /// Segundos actuales (para que Settings muestre el valor persistido).
  double get crossfadeSeconds => _crossfadeSeconds;

  /// true si el wrapper de crossfade está activo (Android/desktop con el
  /// backend envuelto).
  bool get crossfadeSupported => _player is CrossfadeBackend;

  /// Cuando la pista está por terminar: monta y arranca la SIGUIENTE en el
  /// reproductor secundario y funde volúmenes. Devuelve true si el cambio
  /// quedó a cargo del crossfade (el `completed` entrante debe ignorarse).
  Future<bool> _maybeStartCrossfade() async {
    final seconds = _crossfadeSeconds;
    if (seconds <= 0 || _crossfading) return false;
    final backend = _player;
    if (backend is! CrossfadeBackend) return false;

    // Solo hay crossfade si hay siguiente pista real (repeat-one y radio no
    // se funden: requieren cambiar de pista conocida antes del fin).
    final hasNext = _queueIndex >= 0 && _queueIndex < _queue.length - 1;
    if (!hasNext) return false;

    final incoming = _queue[_queueIndex + 1];
    final incomingIndex = _queueIndex + 1;
    final current = _currentTrack;
    if (current == null) return false;

    _crossfading = true;
    try {
      // Resuelve la fuente ENTRANTE con la MISMA canalización que un cambio
      // normal (caché en disco/yt-dlp). Sin token check aquí: el fade se
      // cancela en open()/pause()/stop() del wrapper si llega otra orden.
      final srcFuture = resolveSource(incoming);
      final enrichFuture = _enrich(incoming);
      final src = await srcFuture;
      await backend.openIncoming(_mediaUri(src));
      await backend.startIncoming();

      // publicar la ENTRANTE al terminar la rampa (los streams del backend
      // ya apuntan al nuevo principal tras el swap).
      await backend.beginFade(
        duration: Duration(milliseconds: (seconds * 1000).round()),
      );
      // Fundido CANCELADO (pause/seek/next del usuario durante la rampa):
      // no se publica la entrante ni se intercambian roles.
      if (backend.fadeCancelled) return false;
      backend.swapAfterFade();

      _queueIndex = incomingIndex;
      _notifyQueueChanged();
      _publishTrack(incoming);
      _openedAt = DateTime.now();
      _lastSourceIsLocal = src.isLocal;
      unawaited(_notifyPlayed(incoming));
      unawaited(_enrichThenApply(incoming, enrichFuture, _playToken));
      _schedulePreloads();
      appLog('TRACK', 'crossfade → ${incoming.id} (${seconds}s)');
      return true;
    } catch (_) {
      return false;
    } finally {
      _crossfading = false;
    }
  }

  /// Punto de entrada del crossfade en la ventana final (posición dentro de
  /// los últimos N segundos): un timer se lanza UNA vez por pista (clave =
  /// id de la pista actual, para re-armar en la ENTRANTE tras el swap).
  bool _crossfadeArmed = false;
  String? _crossfadeArmedFor;
  Timer? _crossfadeStartTimer;

  void _checkCrossfadeWindow(Duration p) {
    final seconds = _crossfadeSeconds;
    if (seconds <= 0) return;
    final dur = _lastDuration;
    if (dur == null || dur <= Duration.zero) return;
    // Ventana: últimos `seconds` de la pista (y solo si la pista es más
    // larga que el propio fundido).
    if (dur <= Duration(milliseconds: (seconds * 1000).round())) return;
    if (p >= dur - Duration(milliseconds: (seconds * 1000).round()) &&
        p < dur) {
      final currentId = _currentTrack?.id;
      if (_crossfadeArmed && _crossfadeArmedFor == currentId) return;
      _crossfadeArmed = true;
      _crossfadeArmedFor = currentId;
      _crossfadeStartTimer?.cancel();
      _crossfadeStartTimer = Timer(Duration.zero, () {
        unawaited(_maybeStartCrossfade());
      });
    }
  }

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

    // Crossfade en curso: el fin real de la pista saliente ya no avanza
    // (la entrante fue montada y publicada por el fundido; su propio fin
    // disparará el siguiente). Si el fundido NO llegó a arrancar (fallo de
    // resolución), el completed avanza con la lógica normal de abajo.
    if (_crossfading) return;

    // Repeat one: replay current track.
    if (repeatMode.value == LoopMode.one && current != null) {
      if (_queueIndex >= 0) {
        await _playAt(_queueIndex);
      } else {
        await _openAndPlay(current);
      }
      return;
    }

    // Next in queue (o repeat all): DIFERIDO si el rate-limit está caliente.
    // El auto-advance no puede morir en un rechazo (se quedaría sin
    // reproducir nada), pero tampoco debe acumularse: un solo timer trailing
    // que se reemplaza.
    if (_queueIndex >= 0 &&
        (_queueIndex < _queue.length - 1 ||
            (_queue.isNotEmpty && repeatMode.value == LoopMode.all))) {
      final target = _queueIndex < _queue.length - 1
          ? _nextIndex()
          : 0;
      final wait = DateTime.now().difference(_lastPlayAt);
      if (wait < kMinTrackInterval) {
        _scheduleAutoAdvance(target, kMinTrackInterval - wait);
      } else {
        await _playAt(target);
      }
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

  /// Auto-advance tras la ventana de rate-limit. Un solo timer: si otro
  /// avance llega antes, este se CANCELA y se reprograma (nunca se acumulan
  /// cambios pendientes).
  void _scheduleAutoAdvance(int index, Duration delay) {
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = Timer(delay, () {
      unawaited(_playAt(index));
    });
  }

  Future<void> _retryPrematureCut(Track current) async {
    _prematureRetries[current.id] = (_prematureRetries[current.id] ?? 0) + 1;
    // SIN toast: un retri automático no es un error del usuario (y en una
    // ráfaga de skips encadenaba "conexión abortada" por cada intento).
    appLog('TRACK', 'retry corte prematuro id=${current.id}');
    if (_queueIndex >= 0) {
      await _playAt(_queueIndex);
    } else {
      await _openAndPlay(current);
    }
  }

  /// Cuántas pistas siguientes se precargan. Las primeras 2 arrancan de inmediato; el servicio de caché limita la concurrencia ([AudioCacheService.maxConcurrentPreloads] = 2) y encola el resto en orden, así las 3-5 nunca compiten por ancho de banda con las 2 prioritarias.
  static const int _preloadAhead = 5;
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
    // Camino 2: las pistas siguientes que YA están en disco se "despiertan" de page cache (isolate leyendo sus primeros bytes). Barato (sin red, fuera del UI thread) y se salta las que ya pasaron por aquí.
    final warm = prepareCached;
    if (warm != null) {
      warm(targets.map((t) => t.id).toList());
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

  /// Reproduce la pista en `index` de la cola; en fallo avanza a la siguiente. [userSkip]: true en next/previous del usuario — los ÚNICOS que pasan por el rate-limit (rechazo instantáneo, sin cola: los taps rápidos NO se acumulan). Las llamadas programáticas (playQueueAt, auto-advance, retry por fallo) NO se limitan: un rechazo aquí las dejaría colgadas (p. ej. playQueue justo tras playQueue en tests/UI).
  Future<bool> _playAt(int index, {bool userSkip = false}) async {
    if (index < 0 || index >= _queue.length) return false;
    if (userSkip) {
      final sinceLast = DateTime.now().difference(_lastPlayAt);
      if (sinceLast < kMinTrackInterval) {
        appLog(
          'TRACK',
          'playAt rate-limited (${sinceLast.inMilliseconds}ms) — descartado',
        );
        return false;
      }
    }
    _lastPlayAt = DateTime.now();
    final token = ++_playToken;
    _queueIndex = index;
    _notifyQueueChanged();
    final track = _queue[index];
    _clearPlaybackState();
    _setPreparing(track);
    final sw = Stopwatch()..start();
    void lap(String what) =>
        appLog('PERF', 'playAt $what +${sw.elapsedMilliseconds}ms id=${track.id}');
    appLog('TRACK', 'preparing id=${track.id} idx=$index');
    try {
      // Pausa el backend ANTES de resolver la fuente. Obligatorio con just_audio: `playing` NO se resetea en setAudioSource y `play()` retorna anticipado sin emitir si ya estaba sonando → `_playing` quedaría false (UI paused/loading) mientras la nueva pista suena. Al pausar aquí, just_audio emite playing=false y luego open()+play() emite true → estado sincronizado. También corta la pista anterior de inmediato (con media_kit open() ya lo hacía; con just_audio setAudioSource no para la anterior mientras resolve descarga la nueva).
      await _player.pause();
      // Resuelve fuente + enrich en paralelo; reproduce de inmediato, enrich luego.
      // La guardia `_openedAt` (completed espurio en <3s) cubre cualquier completed fantasma.
      final srcFuture = resolveSource(track);
      final enrichFuture = _enrich(track);
      final src = await srcFuture;
      lap('source ok local=${src.isLocal}');
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      _openedAt = DateTime.now();
      if (kNoAudioMount) {
        // EXPERIMENTO kNoAudioMount: no open/play (audio no montado).
        // El resto del pipeline corre igual: publish → artwork/acento/letras.
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
      // Bearable error: if another track was already requested (new token), this failure is from the old attempt — do not toast it (it was part of the "connection aborted" spam in bursts of skips).
      if (token == _playToken) {
        _errorController.add('No se pudo reproducir "${track.title}": $e');
        if (_queueIndex < _queue.length - 1) {
          return _playAt(_queueIndex + 1);
        }
      }
      return false;
    } finally {
      if (token == _playToken) _setPreparing(null);
    }
  }

  /// Abre y reproduce una pista suelta (fuera de cola).
  Future<bool> _openAndPlay(Track track) async {
    final token = ++_playToken;
    _clearPlaybackState();
    _setPreparing(track);
    try {
      // Igual que en `_playAt`: pausar el backend mantiene sincronizado `playing` (just_audio no emite en play() si ya estaba sonando).
      await _player.pause();
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
      if (token == _playToken) _setPreparing(null);
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

  /// EXPERIMENTO kNoAudioMount: arranca/para la reproducción simulada.
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

  /// Publica la pista en preparación (id + objeto) y la limpia al terminar. Mantiene ambos notifiers sincronizados.
  void _setPreparing(Track? track) {
    preparingTrackId.value = track?.id;
    preparingTrack.value = track;
  }

  /// Resetea el estado de reproducción a vacío mientras carga la nueva pista.
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

  /// Actualiza metadatos tras edición manual, sin tocar la reproducción.
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

  /// Aplica el enrich de Deezer en background. Salta si la pista cambió.
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

  /// URI usable por el backend: stream remoto o archivo local.
  static String _mediaUri(PlayableSource src) {
    if (!src.isLocal) return src.uri;
    return Uri.file(src.uri).toString();
  }

  Future<void> dispose() async {
    _fakeTimer?.cancel();
    _fakeTimer = null;
    _crossfadeStartTimer?.cancel();
    _crossfadeStartTimer = null;
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
    preparingTrack.dispose();
    _slideIntent.dispose();
    _autoAdvanceTimer?.cancel();
    unawaited(_slideRequests.close());
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
