import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

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

  /// Busca canciones similares (mismo artista/género) para el modo radio.
  /// Opcional: si es null, el modo radio se desactiva automáticamente.
  final Future<List<Track>> Function(Track track)? recommend;

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

  /// Id de la pista que se está preparando (descargando al caché o abriendo
  /// el medio), o `null` cuando no hay ninguna. Es un [ValueNotifier] para
  /// que un widget construido *después* de empezar la preparación también
  /// vea el estado actual.
  final ValueNotifier<String?> preparingTrackId = ValueNotifier<String?>(null);

  /// Modo de repetición actual (expuesto a la UI).
  final ValueNotifier<LoopMode> repeatMode =
      ValueNotifier<LoopMode>(LoopMode.off);

  /// Modo aleatorio activo (expuesto a la UI).
  final ValueNotifier<bool> shuffle = ValueNotifier<bool>(false);

  /// Modo radio activo: al agotar la cola, busca del mismo artista.
  /// Activo por defecto (recomendación automática al terminar una canción).
  final ValueNotifier<bool> radio = ValueNotifier<bool>(true);

  bool _playing = false;
  Duration _lastPosition = Duration.zero;
  Track? _currentTrack;

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

  PlayerService({required this.resolveSource, this.recommend}) {
    _player.stream.position.listen((p) {
      _lastPosition = p;
      _positionController.add(p);
    });
    _player.stream.duration.listen((d) => _durationController.add(d));
    _player.stream.playing.listen((p) {
      _playing = p;
      _playingController.add(p);
    });
    _player.stream.buffering.listen(_bufferingController.add);
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
    _queue.clear();
    _queueIndex = -1;
    _prematureRetries.clear();
    return _openAndPlay(track);
  }

  /// Reproduce una lista de pistas como cola, empezando por [startIndex].
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    _queue
      ..clear()
      ..addAll(tracks);
    _prematureRetries.clear();
    await _playAt(startIndex);
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

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> stop() => _player.stop();

  /// Cicla el modo de repetición: off → all → one → off.
  void toggleRepeat() {
    repeatMode.value = switch (repeatMode.value) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
  }

  /// Activa/desactiva el modo aleatorio.
  void toggleShuffle() => shuffle.value = !shuffle.value;

  /// Activa/desactiva el modo radio.
  void toggleRadio() => radio.value = !radio.value;

  // ------------------------------------------------------------- interno
  /// Decide qué reproducir cuando una pista termina.
  Future<void> _onTrackCompleted() async {
    final token = _playToken;
    final current = _currentTrack;

    // Guardia anti-corte: si un stream remoto "terminó" tras pocos segundos
    // y no se ha reintentado aún, se cortó (expiración/rate-limit). Se
    // reintenta una vez con una fuente recién resuelta.
    if (!_lastSourceIsLocal &&
        current != null &&
        _lastPosition > Duration.zero &&
        _lastPosition < const Duration(seconds: 8) &&
        (_prematureRetries[current.id] ?? 0) < 1) {
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

  /// Índice siguiente respetando el modo aleatorio.
  int _nextIndex() {
    if (!shuffle.value || _queue.length <= 1) {
      return _queueIndex + 1;
    }
    // Elegir un índice distinto al actual
    var idx = _random.nextInt(_queue.length);
    var guard = 0;
    while (idx == _queueIndex && guard < 10) {
      idx = _random.nextInt(_queue.length);
      guard++;
    }
    return idx;
  }

  /// Modo radio: busca canciones del mismo artista y las encola.
  Future<void> _playRadio(Track base) async {
    try {
      final tracks = await recommend!(base);
      if (tracks.isEmpty) return;
      // Evitar repetir la pista actual y las ya encoladas
      final known = _queue.map((t) => t.id).toSet()..add(base.id);
      final fresh = tracks.where((t) => !known.contains(t.id)).toList();
      if (fresh.isEmpty) return;
      _queue.addAll(fresh);
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
    final track = _queue[index];
    _currentTrack = track;
    _trackController.add(track);
    preparingTrackId.value = track.id;
    try {
      final src = await resolveSource(track);
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      await _player.open(Media(_mediaUri(src)));
      if (token != _playToken) return false;
      await _player.play();
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
    _currentTrack = track;
    _trackController.add(track);
    preparingTrackId.value = track.id;
    try {
      final src = await resolveSource(track);
      if (token != _playToken) return false;
      _lastSourceIsLocal = src.isLocal;
      await _player.open(Media(_mediaUri(src)));
      if (token != _playToken) return false;
      await _player.play();
      return true;
    } catch (e) {
      _errorController.add('No se pudo reproducir "${track.title}": $e');
      return false;
    } finally {
      if (token == _playToken) preparingTrackId.value = null;
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
  }
}
