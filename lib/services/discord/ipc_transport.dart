import 'ipc_codec.dart';

/// Evento emitido por el transporte hacia el servicio.
sealed class DiscordIpcEvent {
  const DiscordIpcEvent();
}

/// Se estableció la conexión y el handshake se completó (`READY`).
class DiscordIpcConnected extends DiscordIpcEvent {
  const DiscordIpcConnected();
}

/// La conexión se perdió (Discord cerró el pipe/socket o error de red).
class DiscordIpcDisconnected extends DiscordIpcEvent {
  const DiscordIpcDisconnected();
}

/// Llegó un frame completo del servidor (no-handshake).
class DiscordIpcMessage extends DiscordIpcEvent {
  const DiscordIpcMessage(this.opcode, this.payload);

  final DiscordOpcode opcode;
  final Map<String, dynamic> payload;
}

/// Interfaz común de los transports de plataforma (Windows y Unix).
abstract interface class DiscordIpcTransport {
  Stream<DiscordIpcEvent> get events;

  Future<void> connect({Duration retryDelay});

  void send(DiscordOpcode opcode, Map<String, dynamic> payload);

  Future<void> close();
}
