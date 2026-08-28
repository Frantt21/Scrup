import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting, ValueNotifier;

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

  /// Id de aplicación de Scrup en Discord Developer Portal. Al estar
  /// embebido, la presencia funciona de fábrica: el handshake IPC solo
  /// necesita el Application ID (público por diseño) — no hace falta
  /// configurar nada. El nombre/ícono que se ve en el perfil es el de la
  /// aplicación de Scrup.
  static const String clientId = '1536098905479970826';

  /// Nombre del asset registrado en Discord Developer Portal para el
  /// ícono redondo (small_image) que aparece en la esquina del thumbnail.
  /// Sube 'app-logo.png' al Developer Portal como 'scrup_icon'.
  static const String _smallImageAsset = 'scrup_icon';

  bool _enabled = false;

  /// Cada cuánto se reintenta conectar cuando Discord no está corriendo.
  static const _retryDelay = Duration(seconds: 5);

  /// Heartbeat: envía PING cada 15s para que Discord no cierre la conexión
  /// (el C lib oficial usa el mismo intervalo).
  static const _heartbeatInterval = Duration(seconds: 15);

  /// Frecuencia con la que se re-publica la actividad mientras suena:
  /// Discord CACHEA la presencia en el perfil y no la refresca sola mientras
  /// la conexión IPC sigue viva (si no, hay que reiniciar Discord para ver
  /// la canción nueva). Re-publicar con el timestamp actualizado también
  /// mantiene el cronómetro sincronizado con la posición real.
  static const _positionSyncInterval = Duration(seconds: 15);

  /// Cada cuánto se RECONECTA el IPC a propósito: Discord solo re-validar la
  /// actividad en el perfil con un handshake nuevo; una conexión de larga
  /// duración queda con la presencia congelada hasta reiniciar el cliente.
  static const _reconnectInterval = Duration(minutes: 3);

  final _events = StreamController<DiscordIpcEvent>.broadcast();
  final _connectionStatus = ValueNotifier<bool>(false);

  /// Instante en que comenzó la pista actual (para timestamps).
  DateTime _trackStartTime = DateTime.now();

  DiscordIpcTransport? _transport;
  StreamSubscription<DiscordIpcEvent>? _transportSub;
  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _heartbeat;
  Timer? _positionSync;
  Timer? _reconnect;
  bool _connected = false;

  /// `true` cuando el servicio ya se liberó (dispose): las reconexiones
  /// programadas no deben re-arrancar el transporte.
  bool _closed = false;

  Track? _track;
  bool _playing = false;
  Duration _position = Duration.zero;

  /// Pista actual (para lecturas puntuales de la UI).
  Track? get currentTrack => _track;

  Stream<DiscordIpcEvent> get events => _events.stream;
  ValueNotifier<bool> get connected => _connectionStatus;

  /// Carga la configuración guardada, arranca el transporte si está
  /// activado y se suscribe a los cambios del reproductor.
  Future<void> start() async {
    try {
      _enabled = await settings.loadDiscordEnabled();
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
    _trackStartTime = DateTime.now().subtract(_position);

    _trackSub = player.currentTrack.listen(_onTrackChanged);
    _playingSub = player.playing.listen((p) {
      final wasPlaying = _playing;
      _playing = p;
      if (p && !wasPlaying) {
        // Al reanudar: ajustar _trackStartTime para que el cronómetro
        // de Discord continúe desde la posición actual.
        _trackStartTime = DateTime.now().subtract(_position);
      }
      _publishPresence();
    });
    _positionSub = player.position.listen((p) => _position = p);

    // Publicar de inmediato si hay una pista restaurada (solo si el
    // transporte ya está conectado o lo estará pronto).
    if (_track != null) {
      // Dar un instante para que la conexión IPC se establezca.
      Timer(const Duration(seconds: 2), () {
        if (_connected) _publishPresence();
      });
    }
  }

  /// (Re)arranca el transporte con el client id embebido. Idempotente: si
  /// ya está corriendo no hace nada.
  void _startTransport() {
    if (_transport != null) return;
    final DiscordIpcTransport transport = Platform.isWindows
        ? DiscordWindowsTransport(clientId)
        : DiscordUnixTransport(clientId);
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

  Future<void> _stopTransport() async {
    _stopTimers();
    _connected = false;
    _connectionStatus.value = false;
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
    // Guardar el instante en que empezó esta pista para calcular
    // timestamps correctos tanto en play como en pausa.
    _trackStartTime = DateTime.now();
    _publishPresence();
  }

  void _onTransportEvent(DiscordIpcEvent event) {
    _events.add(event);
    switch (event) {
      case DiscordIpcConnected():
        _connected = true;
        _connectionStatus.value = true;
        _startTimers();
        // Publicar de inmediato; Discord en Windows a veces "pierde" el
        // primer SET_ACTIVITY tras un handshake nuevo. Un segundo envío
        // 2 s después obliga a Discord a refrescar la presencia en el
        // perfil SIN necesidad de reiniciar el cliente.
        _publishPresence();
        Timer(const Duration(seconds: 2), () {
          if (_connected) _publishPresence();
        });
        // Programar la próxima reconexión: fuerza a Discord a re-validar la
        // actividad en el perfil (workaround del cacheo de Rich Presence).
        _reconnect?.cancel();
        _reconnect = Timer(_reconnectInterval, () {
          debugPrint('[discord] reconectando para refrescar la presencia…');
          unawaited(_forceReconnect());
        });
      case DiscordIpcDisconnected():
        _connected = false;
        _connectionStatus.value = false;
        _stopTimers();
      case DiscordIpcMessage(:final opcode, :final payload):
        if (opcode == DiscordOpcode.ping) {
          _transport?.send(DiscordOpcode.pong, {});
        } else if (opcode == DiscordOpcode.frame) {
          // El READY (evt=READY) o el ack de SET_ACTIVITY confirman que el
          // comando llegó a Discord.
          debugPrint('[discord] frame: ${payload['evt'] ?? payload['cmd']}');
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
    _reconnect?.cancel();
    _reconnect = null;
  }

  /// Cierra y reabre el transporte IPC: el handshake nuevo hace que Discord
  /// re-validar la actividad y la muestre sin reiniciar el cliente.
  Future<void> _forceReconnect() async {
    if (_transport == null) return;
    final wasEnabled = _enabled;
    await _stopTransport();
    if (_closed) return;
    if (wasEnabled) _startTransport();
  }

  /// Publica (o limpia) la actividad según el estado del reproductor.
  ///
  /// Cuando está pausado se publica SIN 'end' timestamp: Discord congela
  /// la barra de progreso (el cronómetro se detiene porque no hay 'end' que
  /// calcular). Al reanudar se re-publica con timestamps nuevos ajustados
  /// a la posición actual.
  void _publishPresence() {
    final transport = _transport;
    if (transport == null || !_connected) return;
    final track = _track;
    if (track == null) {
      debugPrint('[discord] sin pista, limpiando actividad');
      transport.send(DiscordOpcode.frame, {
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': pid, 'activity': null},
        'nonce': _nonce(),
      });
      return;
    }

    final activity = buildActivity(
      track: track,
      trackStartTime: _trackStartTime,
      total: track.duration ?? player.durationValue,
      playing: _playing,
    );

    debugPrint('[discord] SET_ACTIVITY: ${track.title} — ${track.artist}');
    transport.send(DiscordOpcode.frame, {
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': pid, 'activity': activity},
      'nonce': _nonce(),
    });
  }

  /// Construye el payload `activity` de SET_ACTIVITY.
  ///
  /// · Tipo LISTENING (2): Discord muestra "♫ Listening to Scrup" como
  ///   header (nombre de la app del Developer Portal — no cambiable por API).
  ///   El título de la canción se muestra en la primera línea debajo.
  /// · Portada como `large_image`: las URL remotas https funcionan sin
  ///   subir assets al portal de desarrolladores.
  /// · Barra de progreso: `timestamps.start` + `end` (solo con duración
  ///   conocida); sin `end` Discord muestra cronómetro simple.
  @visibleForTesting
  static Map<String, dynamic>? buildActivity({
    required Track track,
    required DateTime trackStartTime,
    Duration? total,
    bool playing = true,
  }) {
    final title = track.title.isNotEmpty ? track.title : 'Unknown';
    final artist = track.artist.isNotEmpty ? track.artist : 'Scrup';

    final thumb = track.thumbnailUrl;
    final album = track.album;

    // Usar trackStartTime como referencia estable: Discord calcula
    // elapsed = now - start, así que start debe ser el instante en que
    // la pista empezó (restándole la posición actual).
    final startSec = trackStartTime.millisecondsSinceEpoch ~/ 1000;
    final totalSec = total?.inSeconds ?? 0;
    final hasEnd = totalSec > 0 && playing;

    return {
      'type': 2, // Listening
      'name': title,
      'details': title,
      'state': artist,
      'timestamps': {
        'start': startSec,
        if (hasEnd) 'end': startSec + totalSec,
      },
      'assets': {
        if (thumb != null && thumb.isNotEmpty) 'large_image': thumb,
        if (album != null && album.isNotEmpty) 'large_text': album,
        'small_image': _smallImageAsset,
        'small_text': 'Scrup',
      },
    };
  }

  /// Id del proceso actual (lo exige el payload SET_ACTIVITY).
  static int get pid => _currentPid;

  /// Nonce aleatorio para correlacionar comandos con acks.
  String _nonce() => 'scrup_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> dispose() async {
    _closed = true;
    _reconnect?.cancel();
    _reconnect = null;
    await _trackSub?.cancel();
    _trackSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _positionSub?.cancel();
    _positionSub = null;
    await _stopTransport();
    await _events.close();
    _connectionStatus.dispose();
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
