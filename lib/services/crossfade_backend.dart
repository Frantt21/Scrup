import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

import 'audio_backend.dart';

import '../core/app_log.dart';

/// Backend con CROSSFADE: envuelve el backend real y mantiene UN SEGUNDO
/// reproductor (mismo tipo, creado vía [incomingFactory]) para montar la
/// pista siguiente mientras la actual se apaga. Mismo enfoque que
/// forawn_mobile: rampa de volumen lineal en N pasos, swap de roles al
/// terminar y el reproductor saliente queda como "incoming" del siguiente
/// crossfade.
///
/// Fuera del fundido es un passthrough transparente: TODOS los streams y
/// comandos delegan en el reproductor principal (los streams van por
/// controladores propios para poder REBINDEARlos al swap, porque las
/// suscripciones de [PlayerService] apuntan a objetos de stream concretos).
class CrossfadeBackend implements AudioBackend {
  CrossfadeBackend(this._main, AudioBackend Function() incomingFactory)
    : _incoming = incomingFactory() {
    _rebindStreams();
  }

  AudioBackend _main;
  AudioBackend _incoming;

  // ── Streams espejo (rebindeados al hacer swap) ────────────────────────
  final _posCtrl = StreamController<Duration>.broadcast();
  final _durCtrl = StreamController<Duration?>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _bufCtrl = StreamController<bool>.broadcast();
  final _errCtrl = StreamController<String>.broadcast();
  final _comCtrl = StreamController<bool>.broadcast();
  final _volCtrl = StreamController<double>.broadcast();

  List<StreamSubscription> _mirrorSubs = [];

  void _rebindStreams() {
    for (final s in _mirrorSubs) {
      s.cancel();
    }
    _mirrorSubs = [
      _main.positionStream.listen(_posCtrl.add),
      _main.durationStream.listen(_durCtrl.add),
      _main.playingStream.listen(_playingCtrl.add),
      _main.bufferingStream.listen(_bufCtrl.add),
      _main.errorStream.listen(_errCtrl.add),
      _main.completedStream.listen(_comCtrl.add),
      // Volumen: durante la rampa NO se espeja (el fade lo cambia en cada
      // paso y el slider de la UI saltaría); al terminar se emite el valor
      // del usuario.
      _main.volumeStream.listen((v) {
        if (!isFading) _volCtrl.add(v);
      }),
    ];
  }

  @override
  Stream<Duration> get positionStream => _posCtrl.stream;

  @override
  Stream<Duration?> get durationStream => _durCtrl.stream;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Stream<bool> get bufferingStream => _bufCtrl.stream;

  @override
  Stream<String> get errorStream => _errCtrl.stream;

  @override
  Stream<bool> get completedStream => _comCtrl.stream;

  @override
  Stream<double> get volumeStream => _volCtrl.stream;

  @override
  bool get isPlaying => _main.isPlaying;

  @override
  ValueListenable<AudioDevice> get audioDevice => _main.audioDevice;

  @override
  ValueListenable<List<AudioDevice>> get audioDevices => _main.audioDevices;

  // ── Crossfade ─────────────────────────────────────────────────────────

  /// Volumen del USUARIO (0..1) sincronizado con cada setVolume externo; la
  /// rampa escala alrededor de este valor (nunca sube más allá).
  double _userVolume = 1.0;

  Timer? _fadeTimer;
  Completer<void>? _fadeDone;

  /// true si el fundido activo fue cancelado (pause/seek/stop/open del
  /// usuario): [swapAfterFade] debe NO-op en vez de intercambiar roles.
  bool _fadeCancelled = false;

  /// Progreso del fundido 0..1 (para el indicador en UI si hace falta).
  final ValueNotifier<double> fadeProgress = ValueNotifier(0);

  bool get isFading => _fadeTimer != null;

  /// true tras un [cancelFade] hasta el próximo [beginFade]: el servicio lo
  /// consulta para saber si la rampa terminó de verdad o fue abortada.
  bool get fadeCancelled => _fadeCancelled;

  /// Arranca la rampa (outgoing↓ / incoming↑). Devuelve el Future que se
  /// completa cuando el fundido TERMINA (o se cancela). El `incoming` debe
  /// abrirse/arrancarse en paralelo con [openIncoming]/[startIncoming].
  Future<void> beginFade({required Duration duration}) {
    if (isFading) return _fadeDone?.future ?? Future.value();
    final done = Completer<void>();
    _fadeDone = done;
    _fadeCancelled = false;
    fadeProgress.value = 0;
    const steps = 60;
    final stepMs = (duration.inMilliseconds ~/ steps).clamp(10, 200);
    var i = 0;
    _fadeTimer = Timer.periodic(Duration(milliseconds: stepMs), (t) {
      i++;
      final p = (i / steps).clamp(0.0, 1.0);
      fadeProgress.value = p;
      unawaited(_main.setVolume(_userVolume * (1 - p)));
      unawaited(_incoming.setVolume(_userVolume * p));
      if (i >= steps) {
        t.cancel();
        _fadeTimer = null;
        // El fade terminó por sí mismo: libera el completer ANTES de que el
        // servicio llame a swapAfterFade (cancelFade tras completar sería
        // un double-complete).
        _fadeDone = null;
        done.complete();
        appLog('TRACK', 'crossfade rampa completada');
      }
    });
    return done.future;
  }

  /// Abre la pista entrante EN PAUSA sobre el reproductor secundario.
  Future<void> openIncoming(String uri) => _incoming.open(uri, play: false);

  /// Arranca la reproducción del secundario (bajo la rampa).
  Future<void> startIncoming() => _incoming.play();

  /// Fin de fundido OK: intercambia roles. El saliente se detiene y queda
  /// como secundario (listo para el próximo crossfade). Si el fundido fue
  /// CANCELADO (el usuario pausó/buscó/cambió), no intercambia.
  void swapAfterFade() {
    fadeProgress.value = 0;
    if (_fadeCancelled) {
      _fadeCancelled = false;
      return;
    }
    final outgoing = _main;
    unawaited(outgoing.stop());
    unawaited(outgoing.setVolume(_userVolume));
    unawaited(_incoming.setVolume(_userVolume));
    _main = _incoming;
    _incoming = outgoing;
    _rebindStreams();
    _volCtrl.add(_userVolume);
    // RE-ANUNCIA el estado del nuevo principal: just_audio NO emite un
    // evento de `playing` al rebindear (ya venía sonando desde la rampa) y
    // PlayerService heredaba el estado del reproductor SALIENTE (que acaba
    // de pararse) → el botón quedaba en pausa aunque la pista sonara.
    _playingCtrl.add(_main.isPlaying);
  }

  /// Cancela el fundido en curso: para el secundario y restaura el volumen
  /// del principal. El Future de [beginFade] se completa (sin swap).
  void cancelFade() {
    if (!isFading) return;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeCancelled = true;
    unawaited(_incoming.stop());
    unawaited(_incoming.setVolume(_userVolume));
    unawaited(_main.setVolume(_userVolume));
    fadeProgress.value = 0;
    _volCtrl.add(_userVolume);
    _fadeDone?.complete();
    _fadeDone = null;
  }

  @override
  Future<void> open(String uri, {bool play = true}) {
    // Abrir sobre el principal corta cualquier fundido en curso (mismo
    // comportamiento que antes del wrapper).
    cancelFade();
    return _main.open(uri, play: play);
  }

  @override
  Future<void> pause() {
    cancelFade();
    return _main.pause();
  }

  @override
  Future<void> play() => _main.play();

  @override
  Future<void> seek(Duration position) {
    cancelFade();
    return _main.seek(position);
  }

  @override
  Future<void> stop() {
    cancelFade();
    return _main.stop();
  }

  @override
  Future<void> setVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    if (!isFading) _userVolume = v;
    return _main.setVolume(isFading ? _mainVolumeDuringFade() : v);
  }

  // Con isFading un setVolume externo no rompe la rampa: se aplica sobre el
  // principal respetando el progreso (el usuario subió/bajó a mitad de fade).
  double _mainVolumeDuringFade() => _userVolume * (1 - fadeProgress.value);

  @override
  Future<void> setAudioDevice(AudioDevice device) =>
      _main.setAudioDevice(device);

  @override
  Future<void> dispose() async {
    _fadeTimer?.cancel();
    for (final s in _mirrorSubs) {
      await s.cancel();
    }
    await _posCtrl.close();
    await _durCtrl.close();
    await _playingCtrl.close();
    await _bufCtrl.close();
    await _errCtrl.close();
    await _comCtrl.close();
    await _volCtrl.close();
    fadeProgress.dispose();
    await _incoming.dispose();
    await _main.dispose();
  }
}
