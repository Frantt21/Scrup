import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../core/track.dart';
import 'player_service.dart';

/// Puente con los **controles multimedia nativos del OS** vía audio_service:
/// - Windows → SMTC (SystemMediaTransportControls: overlay de medios y
///   teclas multimedia), implementado por el paquete `audio_service_win`
///   (audio_service NO soporta Windows: usa un NoOp por defecto). Nota:
///   `audio_service_win` no implementa la línea de tiempo, así que la barra
///   de progreso/seek del SMTC no aparece en Windows.
/// - macOS → Now Playing (lock screen / Control Center).
/// - Linux → MPRIS (con el paquete compañero `audio_service_mpris`).
///
/// Expone la pista actual (título/artista/álbum/portada/duración) y el estado
/// de reproducción (play/pausa + posición), y reenvía los comandos del OS
/// (play, pausa, anterior, siguiente, seek) al [PlayerService].
///
/// Se crea ANTES de `runApp` (AudioService.init) y se conecta al reproductor
/// cuando el árbol de providers construye el [PlayerService] ([attach]).
class ScrupAudioHandler extends BaseAudioHandler with SeekHandler {
  PlayerService? _player;
  final List<StreamSubscription> _subs = [];

  bool _hasTrack = false;
  bool _playing = false;
  Duration _lastPosition = Duration.zero;

  /// Último segundo publicado (throttle de la posición del SMTC a ~1 Hz:
  /// actualizaciones más frecuentes causan tirones en el overlay de Windows).
  int _lastPublishedSec = -1;

  /// Conecta el handler al reproductor: sincroniza metadatos y estado, y
  /// empieza a recibir comandos del OS. Idempotente.
  void attach(PlayerService player) {
    if (_player != null) return;
    _player = player;
    _subs.addAll([
      player.currentTrack.listen((track) {
        if (track == null) {
          _hasTrack = false;
          // audio_service ignora los items nulos: el SMTC conserva la
          // metadata anterior hasta que llegue la nueva pista (el estado se
          // publica solo cuando hay pista, ver _publishPlaybackState).
          mediaItem.add(null);
          return;
        }
        _hasTrack = true;
        mediaItem.add(_mediaItemFor(track));
        // Publicar el estado JUNTO con la metadata: el nativo de Windows
        // solo fija el PlaybackStatus en updateState (no en setMediaItem), y
        // sin este publish el SMTC quedaría con un estado indefinido — p. ej.
        // al restaurar la sesión pausada (nunca llega un evento playing) o si
        // el evento `playing` del nuevo medio llega antes de publicar la
        // pista (race en el cambio de canción).
        _publishPlaybackState();
      }),
      player.playing.listen((playing) {
        _playing = playing;
        _publishPlaybackState();
      }),
      // Posición: alimenta la barra de progreso del SMTC (throttle ~1 Hz).
      player.position.listen((pos) {
        _lastPosition = pos;
        final sec = pos.inMilliseconds ~/ 1000;
        if (sec == _lastPublishedSec) return;
        _lastPublishedSec = sec;
        _publishPlaybackState();
      }),
    ]);
    // Sin pista no se publica nada (guardia de _publishPlaybackState): el
    // SMTC/Now Playing/MPRIS no se encienden vacíos; el primer estado real
    // llega con la primera pista vía el listener de currentTrack.
  }

  /// Convierte una pista en el [MediaItem] que ve el OS.
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

  /// Publica el estado de reproducción en el OS. Sin pista NO se publica
  /// nada: audio_service reenvía cada estado al platform, y en Windows eso
  /// encendería un SMTC vacío (sin metadata) al arrancar. El estado correcto
  /// se publica en cuanto llega la primera pista (que es cuando el OS
  /// empieza a mostrar el overlay).
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
    // Forzar la publicación del siguiente evento de posición: si el seek cae
    // en el mismo segundo ya publicado, el throttle lo silenciaría y la barra
    // del OS no reflejaría el salto hasta el próximo segundo.
    _lastPublishedSec = -1;
    await _player?.seek(position);
  }

  @override
  Future<void> stop() async {
    // Publicar PAUSADO antes de limpiar la pista: así el OS refleja el
    // estado correcto (si se limpiara primero, _publishPlaybackState no
    // publicaría nada por la guardia de _hasTrack).
    _playing = false;
    _publishPlaybackState();
    _hasTrack = false;
    mediaItem.add(null);
    // Pausar en vez de `_player.stop()`: stop() de media_kit emite el evento
    // `completed`, que el PlayerService interpreta como fin de canción y
    // dispararía el auto-advance/radio (el propio servicio evita stop() por
    // ese motivo).
    await _player?.pause();
  }

  /// Cancela las suscripciones al reproductor. Best-effort: la app de
  /// escritorio termina con el proceso, así que normalmente no hace falta.
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
