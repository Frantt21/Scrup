import 'dart:async';

import 'package:audio_session/audio_session.dart'
    show AudioSession, AudioSessionConfiguration;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

import 'audio_backend.dart';

/// Backend de audio sobre just_audio (ExoPlayer/Media3) para Android.
///
/// A diferencia de media_kit/libmpv, ExoPlayer REUTILIZA el pipeline de
/// audio (AudioTrack + decodificadores) entre pistas: `setAudioSource` es
/// barato y el cambio de canción no derriba/reconstruye el demuxer ni la
/// salida. Es lo que hace forawn_mobile y por eso sus transiciones van a
/// 80-90Hz.
class JustAudioBackend implements AudioBackend {
  final AudioPlayer _player = AudioPlayer();

  // ExoPlayer enruta la salida automáticamente (sin selector manual): se
  // exponen los notifiers vacíos para mantener la API de [AudioBackend]; el
  // menú de dispositivos de desktop no se muestra con devices vacíos.
  final ValueNotifier<AudioDevice> _audioDevice = ValueNotifier(
    AudioDevice.auto(),
  );

  final ValueNotifier<List<AudioDevice>> _audioDevices = ValueNotifier(
    const <AudioDevice>[],
  );

  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<bool>.broadcast();

  // El stream de errores se mantiene vacío: just_audio lanza excepciones
  // desde setAudioSource/play (capturadas por PlayerService).
  final _errorController = StreamController<String>.broadcast();

  final List<StreamSubscription> _subs = [];

  JustAudioBackend() {
    unawaited(_configureSession());
    _subs.addAll([
      // buffering derivado del estado: preparando la fuente o rebufando.
      _player.playerStateStream.listen((state) {
        final loading =
            state.processingState == ProcessingState.loading ||
            state.processingState == ProcessingState.buffering;
        _bufferingController.add(loading);
      }),
      // Errores: just_audio los lanza como excepciones desde setAudioSource/
      // play → los captura PlayerService (fallback a la siguiente pista). El
      // stream queda vacío para mantener la API del backend.
      _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          _completedController.add(true);
        }
      }),
    ]);
  }

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {
      // Best-effort: sin sesión de audio la app sigue reproduciendo.
    }
  }

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  bool get isPlaying => _player.playing;

  @override
  Stream<double> get volumeStream => _player.volumeStream;

  @override
  ValueListenable<AudioDevice> get audioDevice => _audioDevice;

  @override
  ValueListenable<List<AudioDevice>> get audioDevices => _audioDevices;

  @override
  Future<void> open(String uri, {bool play = true}) async {
    // setAudioSource NO reproduce por sí solo: el arranque lo hace play().
    await _player.setAudioSource(AudioSource.uri(Uri.parse(uri)));
    if (play) await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setVolume(double volume) {
    return _player.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    // El enrutado de salida en Android es automático (ExoPlayer).
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _bufferingController.close();
    await _errorController.close();
    await _completedController.close();
    _audioDevice.dispose();
    _audioDevices.dispose();
    await _player.dispose();
  }
}