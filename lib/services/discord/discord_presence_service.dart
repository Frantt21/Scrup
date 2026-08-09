import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../../core/track.dart';
import '../player_service.dart';
import '../settings_store.dart';
import 'discord_unix_transport.dart';
import 'discord_windows_transport.dart';
import 'ipc_codec.dart';
import 'ipc_transport.dart';

/// Cliente de Discord Rich Presence para Scrup.
///
/// Conecta al IPC local de Discord (named pipe en Windows vía FFI, sockets
/// en Linux/macOS), completa el handshake y publica la canción en
/// reproducción como actividad: título/álbum, artista, portada (URL remota
/// de YouTube) y timestamps de inicio (con el recorrido actual).
///
/// Sin librería nativa: solo Dart + FFI del propio OS, por lo que funciona
/// en Windows, Linux y macOS sin empaquetar binarios.
class DiscordPresenceService {
  DiscordPresenceService({required this.player, required this.settings});

  final PlayerService player;
  final SettingsStore settings;

  /// Id de aplicación por defecto en Discord Developer Portal. El usuario
  /// debe crear su propia aplicación y pegar su id en Configuración; con el
  /// id por defecto el handshake falla y la presencia simplemente no se
  /// activa (los assets de la portada se resuelven por URL remota, no
  /// requieren subir assets).
  static const String defaultClientId = '0';

  /// Client id en uso (default o el guardado por el usuario).
  String _clientId = defaultClientId;
  bool _enabled = false;

  /// Cada cuánto se reintenta conectar cuando Discord no está corriendo.
  static const _retryDelay = Duration(seconds: 5);

  /// Heartbeat: envía PING cada 15s para que Discord no cierre la conexión
  /// (el C lib oficial usa el mismo intervalo).
  static const _heartbeatInterval = Duration(seconds: 15);

  /// Frecuencia con la que se refresca el timestamp de inicio mientras
  /// suena: Discord muestra un cronómetro desde `start`, y sin refresco el
  /// recorrido mostrado se quedaría congelado al valor de la última
  /// actualización.
  static const _positionSyncInterval = Duration(seconds: 10);

  final _events = StreamController<DiscordIpcEvent>.broadcast();

  DiscordIpcTransport? _transport;
  StreamSubscription<DiscordIpcEvent>? _transportSub;
  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _heartbeat;
  Timer? _positionSync;
  bool _connected = false;

  Track? _track;
  bool _playing = false;
  Duration _position = Duration.zero;

  /// Pista actual (para lecturas puntuales de la UI).
  Track? get currentTrack => _track;

  Stream<DiscordIpcEvent> get events => _events.stream;

  /// Carga la configuración guardada, arranca el transporte si está
  /// activado y se suscribe a los cambios del reproductor.
  Future<void> start() async {
    try {
      _enabled = await settings.loadDiscordEnabled();
      final savedId = await settings.loadDiscordClientId();
      if (savedId != null && savedId.trim().isNotEmpty) {
        _clientId = savedId.trim();
      }
    } catch (_) {
      // La configuración nunca debe romper el arranque.
    }
    if (_enabled) {
      _startTransport();
    }

    // Estado inicial (puede haber una pista restaurada de la sesión).
    _track = player.currentTrackValue;
    _playing = player.isPlaying;
    _position = player.positionValue;

    _trackSub = player.currentTrack.listen(_onTrackChanged);
    _playingSub = player.playing.listen((p) {
      _playing = p;
      _publishPresence();
    });
    _positionSub = player.position.listen((p) => _position = p);
  }

  /// (Re)arranca el transporte con el client id actual. Idempotente: si ya
  /// está corriendo con el mismo id no hace nada.
  void _startTransport() {
    if (_transport != null) return;
    final DiscordIpcTransport transport = Platform.isWindows
        ? DiscordWindowsTransport(_clientId)
        : DiscordUnixTransport(_clientId);
    _transport = transport;
    _transportSub = transport.events.listen(_onTransportEvent);
    unawaited(transport.connect(retryDelay: _retryDelay));
  }

  /// Activa/desactiva la presencia desde Configuración (persiste y aplica
  /// al instante).
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await settings.saveDiscordEnabled(enabled);
    if (enabled) {
      _startTransport();
    } else {
      await _stopTransport();
    }
  }

  /// Actualiza el client id desde Configuración: reinicia el transporte si
  /// estaba activo para que el handshake use el id nuevo.
  Future<void> setClientId(String clientId) async {
    final trimmed = clientId.trim();
    if (trimmed == _clientId) return;
    _clientId = trimmed.isEmpty ? defaultClientId : trimmed;
    await settings.saveDiscordClientId(_clientId);
    if (_enabled && _transport != null) {
      await _stopTransport();
      _startTransport();
    }
  }

  Future<void> _stopTransport() async {
    _stopTimers();
    _connected = false;
    await _transportSub?.cancel();
    _transportSub = null;
    final t = _transport;
    _transport = null;
    await t?.close();
  }

  /// `true` si el IPC está conectado y la presencia activa (depuración/UI).
  bool get active => _connected && _enabled;

  void _onTrackChanged(Track? track) {
    _track = track;
    _position = Duration.zero;
    _publishPresence();
  }

  void _onTransportEvent(DiscordIpcEvent event) {
    _events.add(event);
    switch (event) {
      case DiscordIpcConnected():
        _connected = true;
        _startTimers();
        _publishPresence();
      case DiscordIpcDisconnected():
        _connected = false;
        _stopTimers();
      case DiscordIpcMessage(:final opcode):
        if (opcode == DiscordOpcode.ping) {
          _transport?.send(DiscordOpcode.pong, {});
        }
    }
  }

  void _startTimers() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      _transport?.send(DiscordOpcode.ping, {});
    });
    _positionSync?.cancel();
    _positionSync = Timer.periodic(_positionSyncInterval, (_) {
      if (_playing) _publishPresence();
    });
  }

  void _stopTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _positionSync?.cancel();
    _positionSync = null;
  }

  /// Publica (o limpia) la actividad según el estado del reproductor.
  void _publishPresence() {
    final transport = _transport;
    if (transport == null || !_connected) return;
    final track = _track;
    if (track == null) {
      transport.send(DiscordOpcode.frame, {
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': pid, 'activity': null},
        'nonce': _nonce(),
      });
      return;
    }

    // Timestamp de inicio (segundos Unix): si está sonando, el cronómetro
    // de Discord arranca en `now - recorrido` para reflejar la posición.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final start = now - _position.inSeconds;

    transport.send(DiscordOpcode.frame, {
      'cmd': 'SET_ACTIVITY',
      'args': {
        'pid': pid,
        'activity': {
          'type': 2, // Listening
          'details': _details(track),
          'state': track.artist.isNotEmpty ? track.artist : 'Scrup',
          'timestamps': {'start': start},
          'assets': {
            if (track.thumbnailUrl != null)
              // URL remota directa (YouTube) como imagen grande
              'large_image': track.thumbnailUrl,
            'large_text': track.title,
            'small_image': 'scrup',
            'small_text': 'Scrup',
          },
          'buttons': [
            {
              'label': 'Escuchar en YouTube',
              'url': 'https://www.youtube.com/watch?v=${track.id}',
            },
          ],
        },
      },
      'nonce': _nonce(),
    });
  }

  /// Línea de detalles: título + álbum (si existe).
  String _details(Track track) {
    final album = track.album;
    return album == null || album.isEmpty
        ? track.title
        : '$track.title · $album';
  }

  /// Id del proceso actual (lo exige el payload SET_ACTIVITY).
  static int get pid => _currentPid;

  /// Nonce aleatorio para correlacionar comandos con acks.
  String _nonce() => 'scrup_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> dispose() async {
    await _trackSub?.cancel();
    _trackSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _positionSub?.cancel();
    _positionSub = null;
    await _stopTransport();
    await _events.close();
  }
}

typedef _GetPidNative = Int32 Function();
typedef _GetPidDart = int Function();

/// pid del proceso actual: `dart:io` no expone un `Process.pid` público en
/// esta versión del SDK, así que se obtiene por plataforma: FFI con
/// `GetCurrentProcessId` en Windows y `echo $$` en Unix.
final int _currentPid = _resolvePid();

int _resolvePid() {
  if (Platform.isWindows) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getPid = kernel32.lookupFunction<_GetPidNative, _GetPidDart>(
        'GetCurrentProcessId',
      );
      return getPid();
    } catch (_) {
      return 0;
    }
  }
  try {
    final result = Process.runSync('sh', ['-c', 'echo "\$\$"']);
    return int.tryParse(result.stdout.toString().trim()) ?? 0;
  } catch (_) {
    return 0;
  }
}
