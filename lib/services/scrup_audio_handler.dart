import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../core/track.dart';
import 'player_service.dart';

/// Puente con los **controles multimedia nativos del OS** vía audio_service:
/// - Windows → SMTC (SystemMediaTransportControls: overlay de medios, teclas
///   multimedia, barra de progreso).
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
          mediaItem.add(null);
          _publishPlaybackState();
          return;
        }
        _hasTrack = true;
        mediaItem.add(_mediaItemFor(track));
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
    _publishPlaybackState();
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

  /// Publica el estado de reproducción en el OS. Sin pista, se publica un
  /// estado inactivo (el OS oculta los controles hasta que haya medios).
  void _publishPlaybackState() {
    final controls = _hasTrack
        ? [
            MediaControl.skipToPrevious,
            _playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ]
        : const <MediaControl>[];
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
    _hasTrack = false;
    _playing = false;
    mediaItem.add(null);
    _publishPlaybackState();
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
