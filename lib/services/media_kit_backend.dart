import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_backend.dart';

/// Backend de audio sobre media_kit (libmpv): se usa en desktop/flatpak.
/// Es la implementación original extraída de [PlayerService]; la lógica de
/// cola/acento/UI no cambia.
class MediaKitBackend implements AudioBackend {
  final Player _player = Player();

  final ValueNotifier<AudioDevice> _audioDevice = ValueNotifier(
    AudioDevice.auto(),
  );

  final ValueNotifier<List<AudioDevice>> _audioDevices = ValueNotifier(
    const <AudioDevice>[],
  );

  final List<StreamSubscription> _subs = [];

  MediaKitBackend() {
    _subs.addAll([
      _player.stream.audioDevice.listen((d) => _audioDevice.value = d),
      _player.stream.audioDevices.listen((d) => _audioDevices.value = d),
    ]);
    _audioDevice.value = _player.state.audioDevice;
    _audioDevices.value = _player.state.audioDevices;
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration?> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  Stream<double> get volumeStream => _player.stream.volume.map(
    (v) => (v / 100.0).clamp(0.0, 1.0),
  );

  @override
  ValueListenable<AudioDevice> get audioDevice => _audioDevice;

  @override
  ValueListenable<List<AudioDevice>> get audioDevices => _audioDevices;

  @override
  Future<void> open(String uri, {bool play = true}) {
    return _player.open(Media(uri), play: play);
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
    return _player.setVolume((volume.clamp(0.0, 1.0) * 100).toDouble());
  }

  @override
  Future<void> setAudioDevice(AudioDevice device) {
    return _player.setAudioDevice(device);
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _audioDevice.dispose();
    _audioDevices.dispose();
    await _player.dispose();
  }
}