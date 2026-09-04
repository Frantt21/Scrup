import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

/// Backend de audio abstraído: media_kit (desktop/flatpak) o just_audio
/// (Android/ExoPlayer). [PlayerService] solo habla con esta interfaz, así el
/// backend se puede cambiar por plataforma sin tocar la lógica de cola,
/// acento, artwork ni la UI.
abstract class AudioBackend {
  Stream<Duration> get positionStream;

  Stream<Duration?> get durationStream;

  Stream<bool> get playingStream;

  Stream<bool> get bufferingStream;

  Stream<String> get errorStream;

  /// Emite `true` cuando la pista llega a su fin (el reproductor decide qué
  /// hacer después).
  Stream<bool> get completedStream;

  /// Estado ACTUAL del reproductor (los streams solo emiten cambios; para
  /// tomar decisiones como el toggle play/pausa hay que consultar esto).
  bool get isPlaying;

  /// Volumen NORMALIZADO 0..1 (los backends lo normalizan internamente).
  Stream<double> get volumeStream;

  ValueListenable<AudioDevice> get audioDevice;

  ValueListenable<List<AudioDevice>> get audioDevices;

  /// Abre [uri] (ya resuelto: `file:///…` o `http(s)://…`). Con [play]=true
  /// arranca la reproducción inmediatamente (una sola llamada nativa).
  Future<void> open(String uri, {bool play = true});

  Future<void> pause();

  Future<void> play();

  Future<void> seek(Duration position);

  Future<void> stop();

  /// Volumen normalizado 0..1.
  Future<void> setVolume(double volume);

  Future<void> setAudioDevice(AudioDevice device);

  Future<void> dispose();
}