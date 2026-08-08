import 'dart:async';

import 'package:media_kit/media_kit.dart' hide Track;

import '../core/track.dart';

/// Envoltura de media_kit (libmpv) para reproducción de audio en streaming.
///
/// Expone streams de Flutter para el estado (reproduciendo, posición,
/// duración, buffer) que la UI puede escuchar.
class PlayerService {
  final Player _player = Player();

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

  bool _playing = false;

  /// Contador de generación: descarta respuestas obsoletas cuando el usuario
  /// cambia de pista rápidamente.
  int _playToken = 0;

  PlayerService() {
    _player.stream.position.listen(_positionController.add);
    _player.stream.duration.listen((d) => _durationController.add(d));
    _player.stream.playing.listen((p) {
      _playing = p;
      _playingController.add(p);
    });
    _player.stream.buffering.listen(_bufferingController.add);
    _player.stream.error.listen((e) {
      _errorController.add(e);
    });
  }

  bool get isPlaying => _playing;

  /// Reproduce una pista a partir de su URL directa (extraída por yt-dlp).
  ///
  /// Devuelve `false` si una pista más nueva la ha reemplazado (carrera).
  Future<bool> playUrl(String url, Track track) async {
    final token = ++_playToken;
    _trackController.add(track);
    await _player.open(Media(url));
    if (token != _playToken) return false; // ya se cambió de pista
    await _player.play();
    return true;
  }

  Future<void> togglePlayPause() => _playing ? _player.pause() : _player.play();

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> stop() => _player.stop();

  Future<void> dispose() async {
    await _player.dispose();
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _trackController.close();
    await _errorController.close();
  }
}
