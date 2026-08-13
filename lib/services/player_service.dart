import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../core/queue_shuffle.dart';
import '../core/track.dart';

/// Modo de repetición del reproductor.
///
/// Nombre propio (no `RepeatMode`) para evitar colisión con el `RepeatMode`
/// de Flutter (animaciones).
enum LoopMode {
  /// Sin repetición: la cola termina al llegar al final.
  off,

  /// Repite toda la cola al llegar al final.
  all,

  /// Repite la canción actual.
  one,
}

/// Fuente de audio resuelta para una pista: una URL de stream o una ruta
/// local (caché). `isLocal` permite distinguir cortes prematuros de un
/// stream remoto (inestable) de un archivo local (confiable).
class PlayableSource {
  final String uri;
  final bool isLocal;

  const PlayableSource(this.uri, {this.isLocal = false});
}

/// Instantánea de la cola para persistirla entre sesiones: los ids en el
/// ORDEN actual, el orden ORIGINAL (pre-shuffle, si lo hay), el índice de la
/// pista actual y la playlist activa (si la reproducción viene de una).
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

/// Envoltura de media_kit (libmpv) para reproducción de audio.
///
/// Gestiona una **cola de reproducción** con:
/// - auto-advance al terminar cada pista (`completed`),
/// - modos de repetición (off/all/one),
/// - modo aleatorio (shuffle),
/// - navegación anterior/siguiente,
/// - modo **radio**: al agotarse la cola, busca más canciones del mismo
///   artista/género vía el callback [recommend] y sigue sonando,
/// - fuentes **cache-first** vía [resolveSource]: los streams de YouTube se
///   descargan al caché local, eliminando los cortes por expiración/limit.
class PlayerService {
  final Player _player = Player();
  final Random _random = Random();

  /// Resuelve la fuente de audio de una pista (caché local o URL de stream),
  /// inyectado en [main].
  final Future<PlayableSource> Function(Track track) resolveSource;

  /// Precarga una pista al caché en segundo plano (recursos limitados): las
  /// siguientes de la cola se descargan mientras suena la actual, para que el
  /// salto de canción sea instantáneo. Opcional y *best-effort*.
  final Future<void> Function(Track track)? preload;

  /// Busca canciones similares (mismo artista/género) para el modo radio.
  /// Opcional: si es null, el modo radio se desactiva automáticamente.
  final Future<List<Track>> Function(Track track)? recommend;

  /// Enriquece los metadatos de una pista (título/artista/álbum/portada vía
  /// Deezer). Opcional y *best-effort*: corre en segundo plano y si devuelve
  /// null o falla, la pista se queda con los metadatos de YouTube.
  final Future<Track?> Function(Track track)? enrich;

  /// Notifica cada pista que realmente empieza a sonar (manual, auto-advance
  /// o radio). Se usa para registrar el historial de reproducciones.
  final Future<void> Function(Track track)? onPlayed;

  /// Notifica cuando llegan metadatos enriquecidos (Deezer) de la pista en
  /// reproducción, para persistirlos (recientes con artwork/álbum reales)
  /// sin bloquear el arranque de la reproducción.
  final Future<void> Function(Track track)? onEnriched;

  /// Notifica cada cambio del modo shuffle (activo/desactivado) para
  /// persistirlo entre sesiones. Opcional y *best-effort*: un fallo de
  /// escritura no debe romper el toggle.
  final Future<void> Function(bool enabled)? onShuffleChanged;

  /// Notifica cada cambio del modo de repetición (off/all/one) para
  /// persistirlo entre sesiones. Opcional y *best-effort*.
  final Future<void> Function(LoopMode mode)? onRepeatChanged;

  /// Notifica cada cambio de la cola (orden, índice y playlist activa) para
  /// persistirla entre sesiones. Opcional y *best-effort*: un fallo de
  /// escritura no debe romper la reproducción.
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

  /// La pista actual (si la hay). Útil para lecturas puntuales, p. ej. que un
  /// widget construido después de publicar la pista (sesión restaurada)
  /// también la vea.
  Track? get currentTrackValue => _currentTrack;

  /// Última duración reportada por el medio (si la hay), para lecturas
  /// puntuales de widgets construidos tarde.
  Duration? get durationValue => _lastDuration;

  /// Última posición reportada por el medio, para lecturas puntuales.
  Duration get positionValue => _lastPosition;

  /// Id de la pista que se está preparando (descargando al caché o abriendo
  /// el medio), o `null` cuando no hay ninguna. Es un [ValueNotifier] para
  /// que un widget construido *después* de empezar la preparación también
  /// vea el estado actual.
  final ValueNotifier<String?> preparingTrackId = ValueNotifier<String?>(null);

  /// Modo de repetición actual (expuesto a la UI).
  final ValueNotifier<LoopMode> repeatMode = ValueNotifier<LoopMode>(
    LoopMode.off,
  );

  /// Modo aleatorio activo (expuesto a la UI).
  final ValueNotifier<bool> shuffle = ValueNotifier<bool>(false);

  /// Modo radio activo: al agotar la cola, busca del mismo artista.
  /// Activo por defecto (recomendación automática al terminar una canción).
  final ValueNotifier<bool> radio = ValueNotifier<bool>(true);

  /// Id de la playlist cuya cola se está reproduciendo (o `null` cuando la
  /// reproducción no viene de una playlist: pista suelta, radio, etc.).
  /// Lo usan el sidebar y el detalle para marcar SOLO la playlist que se
  /// está reproduciendo de verdad (no todas las que contienen la pista).
  final ValueNotifier<int?> activePlaylistId = ValueNotifier<int?>(null);

  /// Volumen de reproducción normalizado (0.0–1.0), expuesto a la UI.
  /// media_kit trabaja en 0–100; aquí se mantiene la escala de la UI.
  final ValueNotifier<double> volume = ValueNotifier<double>(1.0);

  bool _playing = false;
  Duration _lastPosition = Duration.zero;
  Track? _currentTrack;
  Duration? _lastDuration;

  /// Intervalo mínimo entre emisiones del stream de posición (throttle en el
  /// origen): media_kit emite decenas de ticks por segundo al reproducir, y
  /// reenviarlos todos a cada suscriptor (barra del player, guardado de
  /// posición, controles del OS, Discord) multiplica el trabajo por tick y
  /// contribuye al consumo de CPU/GPU en reproducción (cada repintado de la
  /// barra compone la ventana). ~250ms (4 repintados/s) es suficiente para
  /// una barra de progreso; la UI siempre lee el valor fresco vía
  /// [positionValue] y el cero (cambio de pista) se emite al instante.
  static const _positionEmitInterval = Duration(milliseconds: 250);
  DateTime? _lastPositionEmit;

  /// Momento en que se abrió el medio actual. media_kit emite un `completed`
  /// espurio al abrir o reemplazar un medio (el `stop` interno de `open`), y
  /// este timestamp permite distinguirlo de un fin de canción real.
  DateTime _openedAt = DateTime.now();

  /// Si la última fuente abierta fue local (caché). La guardia anti-corte
  /// solo aplica a streams remotos, que son los que pueden cortarse por
  /// expiración/rate-limit; un archivo local no debería cortarse, y un
  /// reintento sobre un archivo corrupto tampoco ayudaría.
  bool _lastSourceIsLocal = true;

  /// Contador de generación: descarta respuestas obsoletas cuando el usuario
  /// cambia de pista rápidamente.
  int _playToken = 0;

  /// Reintentos por corte prematuro, por id de pista. Se resetea cuando el
  /// usuario inicia reproducción manualmente (no en los auto-avances, para
  /// no caer en reintentos infinitos).
  final Map<String, int> _prematureRetries = {};

  /// Cola de reproducción (solo reproducción individual si está vacía).
  final List<Track> _queue = [];
  int _queueIndex = -1;

  /// Orden original de la cola (antes de barajarla al activar shuffle),
  /// para restaurarlo al desactivarlo (como Spotify). Null cuando no hay
  /// nada que restaurar. Se guarda al activar shuffle o al reproducir una
  /// cola con shuffle activo; se limpia al vaciar la cola (playTrack /
  /// restoreLastTrack) y tras restaurarlo.
  List<Track>? _originalQueue;

  /// Cola expuesta a la UI (panel de cola). [ValueNotifier] con lista
  /// inmutable: la UI la lee puntualmente y reacciona a los cambios.
  final ValueNotifier<List<Track>> queue = ValueNotifier<List<Track>>(const []);

  /// Índice de la pista actual dentro de la cola (o -1).
  final ValueNotifier<int> queueIndex = ValueNotifier<int>(-1);

  /// Publica el estado de la cola a la UI y persiste la instantánea
  /// (best-effort) para reanudarla en la próxima sesión.
  void _notifyQueueChanged() {
    queue.value = List.unmodifiable(_queue);
    queueIndex.value = _queueIndex;
    final cb = onQueueChanged;
    if (cb != null) unawaited(_notifyQueuePersist(cb, _queueSnapshot()));
  }

  /// Construye la instantánea actual de la cola (orden, orden pre-shuffle,
  /// índice y playlist activa) para persistirla.
  QueuePersistenceSnapshot _queueSnapshot() {
    return QueuePersistenceSnapshot(
      trackIds: _queue.map((t) => t.id).toList(),
      originalTrackIds: _originalQueue?.map((t) => t.id).toList(),
      index: _queueIndex,
      playlistId: activePlaylistId.value,
    );
  }

  /// Instantánea ACTUAL de la cola. Se usa para persistirla en el momento en
  /// que se necesita (p. ej. al cerrar la ventana, para no perder el último
  /// cambio pendiente del debounce).
  QueuePersistenceSnapshot get queueSnapshot => _queueSnapshot();

  /// Persiste la instantánea de la cola de forma segura: nunca lanza (un
  /// fallo de escritura es secundario a la reproducción).
  Future<void> _notifyQueuePersist(
    Future<void> Function(QueuePersistenceSnapshot) cb,
    QueuePersistenceSnapshot snapshot,
  ) async {
    try {
      await cb(snapshot);
    } catch (_) {
      // Silencioso: la persistencia de la cola es secundaria.
    }
  }

  /// Volumen previo antes de silenciar, para restaurarlo al desmutear.
  double _lastVolumeBeforeMute = 1.0;

  PlayerService({
    required this.resolveSource,
    this.recommend,
    this.enrich,
    this.preload,
    this.onPlayed,
    this.onEnriched,
    this.onShuffleChanged,
    this.onRepeatChanged,
    this.onQueueChanged,
  }) {
    _player.stream.position.listen((p) {
      _lastPosition = p;
      // Throttle en el origen (ver _positionEmitInterval): los suscriptores
      // reciben como mucho una emisión cada ~150ms. El cero (cambio de pista
      // o reinicio) se emite al instante para que la UI se resetee ya.
      final now = DateTime.now();
      if (p == Duration.zero ||
          _lastPositionEmit == null ||
          now.difference(_lastPositionEmit!) >= _positionEmitInterval) {
        _lastPositionEmit = now;
        _positionController.add(p);
      }
    });
    _player.stream.duration.listen((d) {
      _lastDuration = d;
      _durationController.add(d);
    });
    _player.stream.playing.listen((p) {
      _playing = p;
      _playingController.add(p);
    });
    _player.stream.buffering.listen(_bufferingController.add);
    _player.stream.volume.listen((v) {
      // media_kit reporta en 0–100; normalizar a 0–1 para la UI
      volume.value = (v / 100.0).clamp(0.0, 1.0);
    });
    _player.stream.error.listen((e) {
      _errorController.add(e);
    });
    // Auto-advance: al terminar una pista, decidir qué sigue
    _player.stream.completed.listen((_) => _onTrackCompleted());
  }

  bool get isPlaying => _playing;

  // ------------------------------------------------------------ control
  /// Reproduce una pista individual, resolviendo su fuente (caché/stream).
  /// Vacía la cola. Devuelve `false` si una pista más nueva la reemplazó
  /// durante la resolución (carrera).
  Future<bool> playTrack(Track track) async {
    // Una pista suelta no pertenece a ninguna playlist activa.
    activePlaylistId.value = null;
    _queue.clear();
    _queueIndex = -1;
    _originalQueue = null;
    _prematureRetries.clear();
    _notifyQueueChanged();
    return _openAndPlay(track);
  }

  /// Restaura la última pista reproducida al arrancar: carga el medio
  /// (pausado, sin historial ni enriquecimiento) y la publica en la UI para
  /// que el usuario pueda continuar con play. Si [positionSeconds] > 0, se
  /// reanuda en ese punto exacto. Best-effort: si la fuente no se resuelve,
  /// la pista no se restaura.
  Future<bool> restoreLastTrack(Track track, {int positionSeconds = 0}) async {
    final token = ++_playToken;
    // La sesión restaurada no trae contexto de playlist.
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

  /// Restaura una cola guardada al arrancar: carga el medio de la pista en
  /// [startIndex] (pausado, sin historial ni enriquecimiento) y publica la
  /// cola completa en la UI para que el usuario pueda reanudar desde donde
  /// quedó. Si [shuffle] sigue activo y se guardó [originalTrackIds], se
  /// restaura también el orden pre-shuffle: al desactivarlo, la cola volverá
  /// al orden de la sesión anterior en vez de quedarse barajada. Best-effort:
  /// si la fuente no se resuelve, la pista no se restaura.
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
    // Restaurar el orden pre-shuffle (solo si el shuffle sigue activo y se
    // guardó un orden con más de una pista).
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

  /// Abre un medio PAUSADO (restauración de sesión): sin reproducir, sin
  /// registrar historial ni enriquecer. Si [positionSeconds] > 0, se reanuda
  /// en ese punto (un fallo de seek no impide la restauración: la pista
  /// queda desde el inicio). Devuelve `false` si una pista más nueva
  /// reemplazó a esta durante la resolución.
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
      // Marcar ANTES de abrir (el `completed` espurio de open cae en la
      // ventana de 3s).
      _openedAt = DateTime.now();
      // `play: false` es OBLIGATORIO aquí: en media_kit, `open()` arranca la
      // reproducción por defecto (`play: true`), y sin esto la canción
      // restaurada empezaría a sonar sola al arrancar la app.
      await _player.open(Media(_mediaUri(src)), play: false);
      if (token != _playToken) return false;
      // Reanudar en el punto exacto guardado (libmpv acota al límite si la
      // duración de la pista es menor).
      if (positionSeconds > 0) {
        try {
          await _player.seek(Duration(seconds: positionSeconds));
        } catch (_) {
          // Silencioso: un fallo de seek deja la pista desde el inicio.
        }
      }
      // Queda pausada y lista; no se reproduce ni se registra historial.
      _publishTrack(track);
      return true;
    } catch (_) {
      // Silencioso: la restauración es best-effort y no debe mostrar errores
      // al arrancar (p. ej. si el caché fue evictado y no hay red).
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
    }
  }

  /// Reproduce una lista de pistas como cola, empezando por [startIndex].
  ///
  /// [playlistId] identifica la playlist de la que viene la cola (si viene
  /// de una): se expone en [activePlaylistId] para que el sidebar y el
  /// detalle marquen solo esa playlist como "en reproducción".
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
      // Guardar el orden original (el de la playlist) para restaurarlo al
      // desactivar shuffle (como Spotify).
      _originalQueue = List.of(_queue);
      if (_queue.length > 1) {
        // Con shuffle la cola se genera aleatoria: la pista elegida queda
        // PRIMERO y el resto se baraja detrás. El reproductor obedece el
        // orden de la cola (secuencial), no salta al azar.
        playIndex = promoteThenShuffle(_queue, playIndex, _random);
      }
    }
    _notifyQueueChanged();
    await _playAt(playIndex);
  }

  /// Reproduce la pista de la cola en [index] SIN tocar la cola (salto
  /// directo desde el panel de cola).
  Future<void> playQueueAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _playAt(index);
  }

  /// Reproduce la siguiente pista de la cola (o radio si se agotó).
  Future<void> next() async {
    final hasNext = _queueIndex >= 0 && _queueIndex < _queue.length - 1;
    if (hasNext) {
      await _playAt(_nextIndex());
      return;
    }
    // Cola agotada: si repeat all, volver al inicio
    if (_queue.isNotEmpty && repeatMode.value == LoopMode.all) {
      await _playAt(0);
      return;
    }
    // Cola agotada o vacía: radio del artista actual
    if (radio.value && recommend != null) {
      final current = _currentTrack;
      if (current != null) {
        await _playRadio(current);
      }
    }
  }

  /// Reproduce la pista anterior (o reinicia si llevamos >3s reproducidos).
  Future<void> previous() async {
    if (_lastPosition > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_queueIndex > 0) {
      await _playAt(_queueIndex - 1);
      return;
    }
    // Primera pista: reiniciar
    await _player.seek(Duration.zero);
  }

  Future<void> togglePlayPause() => _playing ? _player.pause() : _player.play();

  /// Reanuda la reproducción (usado por los controles nativos del OS).
  Future<void> play() => _player.play();

  /// Pausa la reproducción (usado por los controles nativos del OS).
  Future<void> pause() => _player.pause();

  Future<void> seek(Duration position) => _player.seek(position);

  /// Establece el volumen (0.0–1.0).
  Future<void> setVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    volume.value = clamped;
    await _player.setVolume(clamped * 100);
  }

  /// Silencia/restaura el sonido recordando el volumen previo.
  Future<void> toggleMute() async {
    if (volume.value > 0) {
      _lastVolumeBeforeMute = volume.value;
      await setVolume(0);
    } else {
      await setVolume(_lastVolumeBeforeMute > 0 ? _lastVolumeBeforeMute : 0.5);
    }
  }

  Future<void> stop() => _player.stop();

  /// Cicla el modo de repetición: off → all → one → off. Persiste la
  /// preferencia entre sesiones (best-effort).
  void toggleRepeat() {
    repeatMode.value = switch (repeatMode.value) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    // Persistir el modo para la próxima sesión (best-effort).
    unawaited(_notifyRepeatChanged(repeatMode.value));
  }

  /// Notifica el cambio de modo de repetición de forma segura: nunca lanza
  /// (un fallo de persistencia es secundario al toggle).
  Future<void> _notifyRepeatChanged(LoopMode mode) async {
    final cb = onRepeatChanged;
    if (cb == null) return;
    try {
      await cb(mode);
    } catch (_) {
      // Silencioso: la persistencia no debe romper el toggle.
    }
  }

  /// Activa/desactiva el modo aleatorio. Al ACTIVARLO se baraja la cola una
  /// sola vez (guardando el orden original para poder restaurarlo) y el
  /// reproductor pasa a seguir el ORDEN de la cola (secuencial), que ya es
  /// aleatorio. Al DESACTIVARLO se restaura el orden original de la cola
  /// (como Spotify), manteniendo la pista actual sonando en su posición
  /// original. Persiste la preferencia entre sesiones (best-effort).
  void toggleShuffle() {
    shuffle.value = !shuffle.value;
    if (shuffle.value) {
      _applyShuffleToQueue();
    } else {
      _restoreQueueOrder();
    }
    // Persistir el modo para la próxima sesión (best-effort).
    unawaited(_notifyShuffleChanged(shuffle.value));
  }

  /// Notifica el cambio de shuffle de forma segura: nunca lanza (un fallo de
  /// persistencia es secundario al toggle).
  Future<void> _notifyShuffleChanged(bool enabled) async {
    final cb = onShuffleChanged;
    if (cb == null) return;
    try {
      await cb(enabled);
    } catch (_) {
      // Silencioso: la persistencia no debe romper el toggle.
    }
  }

  /// Baraja la cola manteniendo la pista actual: sigue sonando, solo cambia
  /// su posición dentro de la cola. La búsqueda es por identidad de
  /// instancia, no por id: con pistas duplicadas se conserva la exacta que
  /// suena (ver [shuffleKeepingCurrent]). Guarda el orden previo para
  /// restaurarlo al desactivar shuffle.
  void _applyShuffleToQueue() {
    if (_queue.length <= 1) return;
    _originalQueue = List.of(_queue);
    final current = _queueIndex >= 0 && _queueIndex < _queue.length
        ? _queue[_queueIndex]
        : null;
    _queueIndex = shuffleKeepingCurrent(_queue, current, _random);
    _notifyQueueChanged();
  }

  /// Restaura el orden original de la cola al desactivar shuffle: las pistas
  /// guardadas en [_originalQueue] vuelven a su orden previo y las añadidas
  /// mientras shuffle estuvo activo (p. ej. radio) se conservan al final, en
  /// su orden relativo actual. La pista en reproducción no se interrumpe:
  /// solo se actualiza su índice dentro de la cola restaurada.
  void _restoreQueueOrder() {
    final saved = _originalQueue;
    _originalQueue = null;
    // El snapshot nunca se guarda vacío (playQueue retorna antes con una
    // lista vacía y _applyShuffleToQueue hace early-return con ≤1 pistas).
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

  /// Activa/desactiva el modo radio.
  void toggleRadio() => radio.value = !radio.value;

  // ------------------------------------------------------------- interno
  /// Decide qué reproducir cuando una pista termina.
  Future<void> _onTrackCompleted() async {
    final token = _playToken;
    final current = _currentTrack;

    // media_kit emite un `completed` falso cada vez que se abre o reemplaza
    // un medio (el `stop` interno de `open`), que NO es un fin de canción
    // real: si llega pocos segundos después de abrir, se ignora. Solo un
    // stream remoto que además murió a los pocos segundos se reintenta.
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

    // Guardia anti-corte: un stream remoto que "terminó" con <8s
    // reproducidos se cortó (expiración/rate-limit) → reintento una vez.
    if (streamCut) {
      await _retryPrematureCut(current);
      return;
    }

    // Repetir la pista actual (modo one), también en reproducción individual
    if (repeatMode.value == LoopMode.one && current != null) {
      if (_queueIndex >= 0) {
        await _playAt(_queueIndex);
      } else {
        await _openAndPlay(current);
      }
      return;
    }

    // Siguiente de la cola (respeta shuffle)
    if (_queueIndex >= 0 && _queueIndex < _queue.length - 1) {
      await _playAt(_nextIndex());
      return;
    }

    // Fin de cola con repeat all
    if (_queue.isNotEmpty && repeatMode.value == LoopMode.all) {
      await _playAt(0);
      return;
    }

    // Modo radio: buscar más del mismo artista/género
    if (radio.value && recommend != null && token == _playToken) {
      final base = _currentTrack;
      if (base != null) {
        await _playRadio(base);
      }
    }
  }

  /// Reintenta una vez una pista cuyo stream remoto se cortó prematuramente.
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

  /// Número de pistas siguientes de la cola que se precargan (concurrencia
  /// limitada por el caché: [AudioCacheService.maxConcurrentPreloads]).
  static const int _preloadAhead = 2;

  /// Pide al caché precargar las siguientes pistas de la cola (recursos
  /// limitados). El reproductor sigue SIEMPRE el orden de la cola —con
  /// shuffle, la cola ya está barajada—, así que precargar las
  /// [_preloadAhead] siguientes es siempre acertado.
  void _schedulePreloads() {
    final fn = preload;
    if (fn == null || _queueIndex < 0 || _queue.isEmpty) return;
    final targets = <Track>[];
    for (var i = 1; i <= _preloadAhead; i++) {
      final idx = _queueIndex + i;
      if (idx >= _queue.length) break;
      targets.add(_queue[idx]);
    }
    for (final t in targets) {
      unawaited(_preloadTrack(fn, t));
    }
  }

  /// Precarga una pista de forma segura: nunca lanza ni molesta al usuario
  /// (una precarga fallida — sin red, 403… — se ignora).
  Future<void> _preloadTrack(
    Future<void> Function(Track) fn,
    Track track,
  ) async {
    try {
      await fn(track);
    } catch (_) {
      // Best-effort: la precarga es una optimización, no un requisito.
    }
  }

  /// Índice siguiente: SIEMPRE secuencial. La aleatoriedad vive en el ORDEN
  /// de la cola (barajada al activar shuffle), no en el reproductor: el
  /// player obedece la cola, la cola no obedece al player.
  int _nextIndex() => _queueIndex + 1;

  /// Modo radio: busca canciones del mismo artista y las encola.
  Future<void> _playRadio(Track base) async {
    try {
      final tracks = await recommend!(base);
      if (tracks.isEmpty) return;
      // Evitar repetir la pista actual y las ya encoladas
      final known = _queue.map((t) => t.id).toSet()..add(base.id);
      final fresh = tracks.where((t) => !known.contains(t.id)).toList();
      if (fresh.isEmpty) return;
      // Con shuffle, las recomendaciones de radio también se barajan al
      // encolarse: el reproductor sigue el orden de la cola.
      if (shuffle.value) fresh.shuffle(_random);
      _queue.addAll(fresh);
      _notifyQueueChanged();
      await _playAt(_queue.length - fresh.length);
    } catch (e) {
      _errorController.add('No se pudo recomendar música: $e');
    }
  }

  /// Reproduce la pista de la cola en [index], avanzando a la siguiente si
  /// la resolución/reproducción falla.
  Future<bool> _playAt(int index) async {
    if (index < 0 || index >= _queue.length) return false;
    final token = ++_playToken;
    _queueIndex = index;
    _notifyQueueChanged();
    final track = _queue[index];
    // La UI se queda sin datos mientras se carga la nueva pista.
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    try {
      // Detener la pista anterior al instante. Se usa pause y no stop porque
      // stop() de media_kit emite el evento `completed`, que dispararía el
      // auto-advance y podría saltar de canción indebidamente.
      await _player.pause();
      // Resolver la fuente y arrancar Deezer en paralelo. La reproducción NO
      // espera a Deezer: empieza en cuanto hay datos reproducibles (el .part)
      // y el enriquecimiento se aplica en segundo plano al llegar (evita la
      // espera visible al reproducir una pista nueva en conexiones rápidas).
      final srcFuture = resolveSource(track);
      final enrichFuture = _enrich(track);
      final src = await srcFuture;
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      // Marcar ANTES de abrir: el `completed` espurio se emite durante el
      // open y debe caer dentro de la ventana de 3s sí o sí.
      _openedAt = DateTime.now();
      await _player.open(Media(_mediaUri(src)));
      if (token != _playToken) return false;
      await _player.play();
      // Publicar la pista (metadatos de YouTube por ahora), registrar el
      // historial y enriquecer en segundo plano (reemplaza la UI y persiste).
      _publishTrack(track);
      unawaited(_notifyPlayed(track));
      unawaited(_enrichThenApply(track, enrichFuture, token));
      // La pista ya suena: precargar las siguientes de la cola en segundo
      // plano (best-effort) para que el próximo salto sea instantáneo.
      _schedulePreloads();
      return true;
    } catch (e) {
      _errorController.add('No se pudo reproducir "${track.title}": $e');
      // Intentar con la siguiente de la cola
      if (_queueIndex < _queue.length - 1) {
        return _playAt(_queueIndex + 1);
      }
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
    }
  }

  /// Abre y reproduce una pista suelta (fuera de cola). Devuelve `false` si
  /// una pista más nueva la reemplazó durante la resolución.
  Future<bool> _openAndPlay(Track track) async {
    final token = ++_playToken;
    // La UI se queda sin datos mientras se carga la nueva pista.
    _clearPlaybackState();
    preparingTrackId.value = track.id;
    try {
      // Silenciar la pista anterior al instante (mismo motivo que en _playAt).
      await _player.pause();
      // Resolver la fuente y arrancar Deezer en paralelo; reproducir primero,
      // enriquecer después en segundo plano (ver _playAt).
      final srcFuture = resolveSource(track);
      final enrichFuture = _enrich(track);
      final src = await srcFuture;
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      // Marcar ANTES de abrir (mismo motivo que en _playAt).
      _openedAt = DateTime.now();
      await _player.open(Media(_mediaUri(src)));
      if (token != _playToken) return false;
      await _player.play();
      // Publicar la pista, registrar el historial y enriquecer en segundo
      // plano (reemplaza la UI y persiste al llegar).
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

  /// Ejecuta el enriquecimiento (sin tope). Captura errores internamente
  /// para que nunca quede un error asíncrono sin manejar, aunque el futuro
  /// no se llegue a esperar.
  Future<Track?> _enrich(Track track) async {
    final fn = enrich;
    if (fn == null) return null;
    try {
      return await fn(track);
    } catch (_) {
      return null;
    }
  }

  /// Vacía el estado de reproducción expuesto a la UI: al cambiar de pista,
  /// el reproductor se queda sin datos mientras la nueva se descarga/carga
  /// (sin restos de la pista anterior en la barra).
  void _clearPlaybackState() {
    _lastPosition = Duration.zero;
    _currentTrack = null;
    _trackController.add(null);
    _positionController.add(Duration.zero);
    _durationController.add(null);
    _playing = false;
    _playingController.add(false);
    _bufferingController.add(false);
  }

  /// Publica la pista actual en la UI.
  void _publishTrack(Track track) {
    _currentTrack = track;
    _trackController.add(track);
  }

  /// Aplica el enriquecimiento de Deezer en segundo plano: cuando llega,
  /// actualiza la UI y la persistencia (recientes con el artwork/álbum de
  /// Deezer). Nunca bloquea la reproducción ni toca nada si la pista ya
  /// cambió (guardia por token). [enrich] ya es best-effort (nunca lanza,
  /// con tope de 8s en Deezer), así que aquí solo se espera y se aplica.
  Future<void> _enrichThenApply(
    Track original,
    Future<Track?> enrichFuture,
    int token,
  ) async {
    final enriched = await enrichFuture;
    if (token != _playToken) return;
    if (enriched == null || enriched.id != original.id) return;
    _publishTrack(enriched);
    final cb = onEnriched;
    if (cb != null) {
      try {
        await cb(enriched);
      } catch (_) {
        // Silencioso: la persistencia de metadatos es secundaria.
      }
    }
  }

  /// Registra la reproducción de una pista en el historial (best-effort:
  /// los fallos de DB no deben romper la reproducción).
  Future<void> _notifyPlayed(Track track) async {
    final cb = onPlayed;
    if (cb == null) return;
    try {
      await cb(track);
    } catch (_) {
      // Silencioso: el historial es secundario a la reproducción.
    }
  }

  /// Convierte una fuente a una URI que libmpv entienda (file:// para rutas).
  static String _mediaUri(PlayableSource src) {
    if (!src.isLocal) return src.uri;
    return Uri.file(src.uri).toString();
  }

  Future<void> dispose() async {
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
    queue.dispose();
    queueIndex.dispose();
  }
}
