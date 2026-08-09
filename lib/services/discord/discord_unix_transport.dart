import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ipc_codec.dart';
import 'ipc_transport.dart';

/// Transporte IPC vía SOCKETS para Linux y macOS (Discord escucha en un
/// socket de archivo en el directorio runtime del usuario, con fallback TCP
/// en 127.0.0.1:6463).
///
/// `dart:io` soporta sockets de dominio Unix de forma nativa, así que aquí
/// no se necesita FFI ni isolates: la lectura es asíncrona con `Socket`.
class DiscordUnixTransport implements DiscordIpcTransport {
  final String clientId;
  final _events = StreamController<DiscordIpcEvent>.broadcast();
  StreamSubscription<Uint8List>? _dataSub;
  Socket? _socket;

  /// Buffer acumulativo de los bytes recibidos (los frames llegan en trozos
  /// arbitrarios y hay que ensamblarlos).
  final BytesBuilder _incoming = BytesBuilder();

  bool _closed = false;

  DiscordUnixTransport(this.clientId);

  @override
  Stream<DiscordIpcEvent> get events => _events.stream;

  /// Conecta intentando los endpoints conocidos en orden (socket de archivo
  /// de Linux/macOS y fallback TCP). Reintenta cada [retryDelay] hasta que
  /// se cierre el transporte o consiga conectar.
  @override
  Future<void> connect({
    Duration retryDelay = const Duration(seconds: 5),
  }) async {
    while (!_closed) {
      try {
        await _tryConnect();
        if (_closed) return;
        // Conectado: se envía el handshake (el READY llega como primer
        // frame vía _handleFrame) y se emite el evento de conexión.
        await _handshake();
        // Guardia anti-race: close() pudo llegar mientras conectábamos.
        if (_closed) return;
        _events.add(const DiscordIpcConnected());
        // La lectura continua se maneja con callbacks; aquí esperamos a que
        // la conexión se caiga.
        await _socket!.done;
        if (_closed) return;
        _events.add(const DiscordIpcDisconnected());
      } catch (_) {
        if (_closed) return;
        _events.add(const DiscordIpcDisconnected());
      }
      await _closeSocket();
      if (_closed) return;
      await Future<void>.delayed(retryDelay);
    }
  }

  /// Intenta una conexión en cada endpoint conocido hasta que uno funcione.
  Future<void> _tryConnect() async {
    final endpoints = _endpoints();
    Object? lastError;
    for (final endpoint in endpoints) {
      try {
        final socket = await Socket.connect(
          endpoint.$1,
          endpoint.$2,
          timeout: const Duration(seconds: 3),
        );
        _socket = socket;
        _incoming.clear();
        _dataSub = socket.listen(
          _onData,
          onError: (Object e) {},
          cancelOnError: true,
        );
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const SocketException('Sin endpoints disponibles');
  }

  /// Devuelve los endpoints a probar según la plataforma, en orden de
  /// preferencia. El socket de archivo se usa cuando existe; el TCP es el
  /// fallback de Discord.
  List<(InternetAddress, int)> _endpoints() {
    final result = <(InternetAddress, int)>[];
    // Discord intenta varios índices (0..9) del socket; nosotros probamos
    // los dos primeros, que son los que usa por defecto.
    final dir = Platform.environment['XDG_RUNTIME_DIR'];
    if (Platform.isLinux && dir != null && dir.isNotEmpty) {
      // En Linux el socket vive en el directorio runtime del usuario.
      for (var i = 0; i < 2; i++) {
        final path = '$dir/discord-ipc-$i';
        if (File(path).existsSync()) {
          result.add((
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          ));
        }
      }
    }
    if (Platform.isMacOS) {
      // En macOS Discord usa un socket en el Application Support (antiguo)
      // o en el directorio runtime (nuevo). Probamos ambos.
      final home = Platform.environment['HOME'];
      final candidates = <String>[
        if (home != null) '$home/Library/Application Support/discord',
        if (dir != null && dir.isNotEmpty) dir,
      ];
      for (final base in candidates) {
        for (var i = 0; i < 2; i++) {
          final path = '$base/discord-ipc-$i';
          if (File(path).existsSync()) {
            result.add((
              InternetAddress(path, type: InternetAddressType.unix),
              0,
            ));
          }
        }
      }
    }
    // Fallback TCP universal (puerto base de Discord + índice).
    for (var i = 0; i < 2; i++) {
      result.add((InternetAddress.loopbackIPv4, 6463 + i));
    }
    return result;
  }

  /// Ensambla los frames a partir de los trozos de bytes recibidos.
  void _onData(Uint8List chunk) {
    _incoming.add(chunk);
    final bytes = _incoming.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 8) {
      final data = ByteData.sublistView(bytes, offset);
      final length = data.getUint32(4, Endian.little);
      if (bytes.length - offset < 8 + length) break; // frame incompleto
      final frameBytes = Uint8List.sublistView(
        bytes,
        offset,
        offset + 8 + length,
      );
      _handleFrame(frameBytes);
      offset += 8 + length;
    }
    if (offset < bytes.length) {
      _incoming.add(Uint8List.sublistView(bytes, offset));
    }
  }

  void _handleFrame(Uint8List frameBytes) {
    try {
      final decoded = DiscordIpcCodec.decodeFrame(frameBytes);
      // El READY del handshake ya se gestiona en el servicio; el resto se
      // reenvía (SET_ACTIVITY acks, pings, etc.).
      _events.add(DiscordIpcMessage(decoded.opcode, decoded.payload));
    } catch (_) {
      // Frame corrupto: se ignora y se sigue con el siguiente.
    }
  }

  /// Envía el handshake inicial (el READY llega como primer frame).
  Future<void> _handshake() async {
    final frame = DiscordIpcCodec.encodeFrame(DiscordOpcode.handshake, {
      'v': 1,
      'client_id': clientId,
    });
    _socket!.add(frame);
    await _socket!.flush();
  }

  /// Envía un comando al servidor (p. ej. SET_ACTIVITY).
  @override
  void send(DiscordOpcode opcode, Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(DiscordIpcCodec.encodeFrame(opcode, payload));
    } catch (_) {
      // Socket cerrado: el reconnect lo retomará.
    }
  }

  Future<void> _closeSocket() async {
    await _dataSub?.cancel();
    _dataSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
    _incoming.clear();
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _closeSocket();
    await _events.close();
  }
}
