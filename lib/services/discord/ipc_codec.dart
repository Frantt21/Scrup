import 'dart:convert';
import 'dart:typed_data';

/// Opcodes del protocolo IPC de Discord.
enum DiscordOpcode {
  /// Handshake: el cliente se presenta con `{"v":1,"client_id":"..."}` y
  /// Discord responde `READY`.
  handshake(0),

  /// Frame/evento de Discord → cliente (p. ej. el `READY`).
  frame(1),

  /// Cierra la conexión (Discord → cliente).
  close(2),

  /// Ping (Discord → cliente).
  ping(3),

  /// Pong (cliente → Discord).
  pong(4);

  const DiscordOpcode(this.value);

  final int value;

  static DiscordOpcode fromValue(int value) {
    for (final op in DiscordOpcode.values) {
      if (op.value == value) return op;
    }
    throw FormatException('Opcode de Discord desconocido: $value');
  }
}

/// Códifica y decodifica los frames del protocolo IPC de Discord.
///
/// Formato: 4 bytes de opcode (little-endian) + 4 bytes de longitud del
/// payload (little-endian) + payload JSON en UTF-8.
///
/// IMPORTANTE (UTF-8 vs UTF-16): la librería C oficial de Discord codifica
/// los payloads como UTF-16LE, lo que corrompe títulos con caracteres
/// no-ASCII (acentos, cirílico, CJK). Este codec usa UTF-8, el formato
/// correcto que espera el propio Discord, así que los metadatos en español,
/// ruso, japonés, coreano y chino llegan intactos.
class DiscordIpcCodec {
  static const int _headerSize = 8;

  /// Codifica un comando/evento en un frame listo para enviar.
  static Uint8List encodeFrame(
    DiscordOpcode opcode,
    Map<String, dynamic> payload,
  ) {
    final json = utf8.encode(jsonEncode(payload));
    final frame = Uint8List(_headerSize + json.length);
    final data = ByteData.sublistView(frame);
    data.setUint32(0, opcode.value, Endian.little);
    data.setUint32(4, json.length, Endian.little);
    frame.setRange(_headerSize, frame.length, json);
    return frame;
  }

  /// Decodifica un frame completo en su opcode y payload JSON.
  static ({DiscordOpcode opcode, Map<String, dynamic> payload}) decodeFrame(
    Uint8List bytes,
  ) {
    if (bytes.length < _headerSize) {
      throw const FormatException('Frame truncado');
    }
    final data = ByteData.sublistView(bytes);
    final opcode = DiscordOpcode.fromValue(data.getUint32(0, Endian.little));
    final length = data.getUint32(4, Endian.little);
    if (length > bytes.length - _headerSize) {
      throw const FormatException('Payload truncado');
    }
    final payload =
        jsonDecode(
              utf8.decode(bytes.sublist(_headerSize, _headerSize + length)),
            )
            as Map<String, dynamic>;
    return (opcode: opcode, payload: payload);
  }
}
