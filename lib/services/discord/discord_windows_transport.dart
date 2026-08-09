import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ipc_codec.dart';
import 'ipc_transport.dart';

/// Transporte IPC de Discord para WINDOWS usando named pipes vía FFI.
///
/// POR QUÉ FFI: `dart:io` NO puede abrir named pipes de Windows
/// (`\\.\pipe\...` devuelve errno 3 aunque el pipe exista; se verificó
/// empíricamente contra Discord corriendo). El transporte corre en un
/// isolate de fondo que hace `CreateFileW`/`ReadFile`/`WriteFile` con
/// bloqueo real (llamadas síncronas que el event loop del main no puede
/// hacer) y comunica con el servicio vía `SendPort`.
class DiscordWindowsTransport implements DiscordIpcTransport {
  final String clientId;

  final _events = StreamController<DiscordIpcEvent>.broadcast();
  ReceivePort? _mainPort;
  SendPort? _isolatePort;
  Isolate? _isolate;
  Completer<void>? _ready;
  bool _closed = false;

  DiscordWindowsTransport(this.clientId);

  @override
  Stream<DiscordIpcEvent> get events => _events.stream;

  /// Arranca el isolate (idempotente) y espera su handshake (`ready`).
  @override
  Future<void> connect({
    Duration retryDelay = const Duration(seconds: 5),
  }) async {
    if (_closed) return;
    if (_isolate != null) return;
    _mainPort = ReceivePort();
    _mainPort!.listen(_onIsolateMessage, onError: (_) {});
    _ready = Completer<void>();
    _isolate = await Isolate.spawn(_isolateEntry, {
      'clientId': clientId,
      'mainPort': _mainPort!.sendPort,
      'retryMs': retryDelay.inMilliseconds,
    });
    // Esperar el `ready` del isolate: los `send()` previos se perderían
    // (el servicio solo publica con `_connected`, pero por robustez se
    // espera aquí antes de devolver).
    await _ready!.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  /// Reenvía los mensajes del isolate al stream del servicio.
  void _onIsolateMessage(dynamic message) {
    if (_closed) return;
    if (message is Map && message['t'] == 'connected') {
      _events.add(const DiscordIpcConnected());
    } else if (message is Map && message['t'] == 'disconnected') {
      _events.add(const DiscordIpcDisconnected());
    } else if (message is Map && message['t'] == 'msg') {
      try {
        final opcode = DiscordOpcode.fromValue(message['opcode'] as int);
        final payload = (message['payload'] as Map).cast<String, dynamic>();
        _events.add(DiscordIpcMessage(opcode, payload));
      } catch (_) {}
    } else if (message is Map && message['t'] == 'ready') {
      // El isolate ya escucha comandos: los `send()` ya son seguros.
      _isolatePort = message['port'] as SendPort?;
      _ready?.complete();
    }
  }

  /// Envía un frame al pipe: el frame se serializa y el isolate lo escribe
  /// (la escritura es síncrona/FFI y no puede hacerse en el main).
  @override
  void send(DiscordOpcode opcode, Map<String, dynamic> payload) {
    final port = _isolatePort;
    if (port == null) return;
    try {
      final bytes = DiscordIpcCodec.encodeFrame(opcode, payload);
      port.send({'t': 'send', 'bytes': bytes});
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    _closed = true;
    final port = _isolatePort;
    if (port != null) {
      try {
        port.send({'t': 'shutdown'});
      } catch (_) {}
    }
    // El isolate puede estar bloqueado en ReadFile; se fuerza su terminación.
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolatePort = null;
    // ReceivePort.close() devuelve void en este SDK (no un Future).
    _mainPort?.close();
    _mainPort = null;
    await _events.close();
  }
}

/// Punto de entrada del isolate: reporta su port al main (`ready`) y corre
/// el bucle de conexión/reconexión al pipe.
///
/// El bucle usa una LECTURA CON TIMEOUT (no bloquea el isolate para
/// siempre): entre frame y frame se drena la cola de comandos del main
/// (sends y shutdown) y se reenvían los mensajes recibidos.
void _isolateEntry(Map<String, dynamic> args) async {
  final clientId = args['clientId'] as String;
  final mainPort = args['mainPort'] as SendPort;
  final retryMs = args['retryMs'] as int;

  final commands = ReceivePort();
  mainPort.send({'t': 'ready', 'port': commands.sendPort});

  // Cola de escrituras pendientes (el main envía frames mientras el
  // isolate lee). Se vacía en el bucle principal.
  final pendingWrites = <List<int>>[];
  var running = true;
  commands.listen((message) {
    if (message is Map && message['t'] == 'shutdown') {
      running = false;
      commands.close();
    } else if (message is Map && message['t'] == 'send') {
      final bytes = message['bytes'] as List<int>?;
      if (bytes != null) pendingWrites.add(bytes);
    }
  }, onError: (_) {});

  while (running) {
    _WinPipe? pipe;
    try {
      pipe = _WinPipe.openAnyDiscordPipe();
      if (pipe == null) {
        await Future<void>.delayed(Duration(milliseconds: retryMs));
        continue;
      }

      // Handshake: se presenta con client_id y espera el READY. El evento
      // `connected` se envía DESPUÉS del READY: el servicio publica la
      // presencia al recibirlo, y para entonces el `ready` (port de
      // comandos) ya llegó al main — si se enviara antes, el primer
      // SET_ACTIVITY se perdería (send() sin port).
      pipe.writeFrame(DiscordOpcode.handshake, {'v': 1, 'client_id': clientId});
      final first = pipe.readFrame(timeout: const Duration(seconds: 8));
      if (first != null) {
        mainPort.send({
          't': 'msg',
          'opcode': first.opcode.value,
          'payload': first.payload,
        });
        mainPort.send({'t': 'connected'});
      } else {
        // Sin READY: pipe sospechoso, se descarta.
        throw const SocketException('Handshake sin respuesta');
      }

      // Bucle principal: drena escrituras y lee con timeout corto.
      while (running) {
        if (pendingWrites.isNotEmpty) {
          final frames = List<List<int>>.from(pendingWrites);
          pendingWrites.clear();
          for (final bytes in frames) {
            pipe.writeRawBytes(bytes);
          }
        }
        final frame = pipe.readFrame(
          timeout: const Duration(milliseconds: 250),
        );
        if (frame == null) {
          if (pipe.closedByPeer) break;
          continue; // timeout: seguir esperando
        }
        mainPort.send({
          't': 'msg',
          'opcode': frame.opcode.value,
          'payload': frame.payload,
        });
      }
    } catch (_) {
      // Fallo de conexión o de I/O: se notifica y se reintenta.
      mainPort.send({'t': 'disconnected'});
    } finally {
      pipe?.close();
    }
    if (!running) break;
    await Future<void>.delayed(Duration(milliseconds: retryMs));
  }
}

// Firma nativa y firma Dart de las funciones de kernel32 usadas. Los
// typedefs son OBLIGATORIOS: el parser de genéricos de este SDK no acepta
// `Function` tipada inline en `lookupFunction<...>`.
typedef _CreateFileWNative =
    Pointer<Void> Function(
      Pointer<Utf16>,
      Int32,
      Int32,
      Pointer<Void>,
      Int32,
      Int32,
      Pointer<Void>,
    );
typedef _CreateFileWDart =
    Pointer<Void> Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    );
typedef _ReadWriteNative =
    Int32 Function(IntPtr, Pointer<Void>, Int32, Pointer<Int32>, Pointer<Void>);
typedef _ReadWriteDart =
    int Function(int, Pointer<Void>, int, Pointer<Int32>, Pointer<Void>);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _GetLastErrorNative = Int32 Function();
typedef _GetLastErrorDart = int Function();

/// Envoltura mínima del named pipe de Discord vía FFI (kernel32.dll).
///
/// Usa buffers reutilizables para leer: evita malloc/free por frame (la
/// lectura es un bucle de espera de hasta 250ms por tick).
class _WinPipe {
  _WinPipe._(this._handle);

  final int _handle;

  /// `true` si la última lectura falló por pipe roto (Discord cerró).
  bool closedByPeer = false;

  /// Búfers reutilizables para el header (8 bytes) y el payload máximo.
  final _headerBytes = Uint8List(8);
  Pointer<Uint8>? _payloadBuffer;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _createFileW = _kernel32
      .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
  static final _readFile = _kernel32
      .lookupFunction<_ReadWriteNative, _ReadWriteDart>('ReadFile');
  static final _writeFile = _kernel32
      .lookupFunction<_ReadWriteNative, _ReadWriteDart>('WriteFile');
  static final _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  static final _getLastError = _kernel32
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

  /// Abre el primer named pipe de Discord disponible (`discord-ipc-0..9`).
  /// Devuelve `null` si Discord no está escuchando.
  static _WinPipe? openAnyDiscordPipe() {
    const desiredAccess = 0xC0000000; // GENERIC_READ | GENERIC_WRITE
    const shareMode = 0x3; // FILE_SHARE_READ | FILE_SHARE_WRITE
    const openExisting = 3; // OPEN_EXISTING

    for (var i = 0; i < 10; i++) {
      // Prefijo \\?\pipe\: el path extendido de Win32 (el que usa Discord).
      final name = '\\\\?\\pipe\\discord-ipc-$i';
      final namePtr = name.toNativeUtf16();
      try {
        final handle = _createFileW(
          namePtr,
          desiredAccess,
          shareMode,
          nullptr,
          openExisting,
          0,
          nullptr,
        );
        // INVALID_HANDLE_VALUE es -1 (0xFFFFFFFFFFFFFFFF)
        if (handle.address != 0xFFFFFFFFFFFFFFFF) {
          return _WinPipe._(handle.address);
        }
      } finally {
        // Liberar el buffer del nombre (malloc interno de toNativeUtf16).
        malloc.free(namePtr);
      }
    }
    return null;
  }

  /// Lee un frame completo con timeout: devuelve `null` si expiró el tiempo
  /// o si el pipe se cerró. Usa lecturas síncronas con `ReadFile`.
  ({DiscordOpcode opcode, Map<String, dynamic> payload})? readFrame({
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    // Header (8 bytes) con deadline.
    final deadline = DateTime.now().add(timeout);
    var offset = 0;
    while (offset < _headerBytes.length) {
      final n = _readSome(_headerBytes, offset, _headerBytes.length - offset);
      if (n == null) {
        closedByPeer = true;
        return null;
      }
      if (n == 0) {
        if (DateTime.now().isAfter(deadline)) return null;
        // Poll corto: el isolate está bloqueado en FFI síncrono, no hay
        // event loop útil; 10ms es un buen balance CPU/latencia.
        sleep(const Duration(milliseconds: 10));
        continue;
      }
      offset += n;
    }

    final headerData = ByteData.sublistView(_headerBytes);
    final opcode = headerData.getUint32(0, Endian.little);
    final length = headerData.getUint32(4, Endian.little);
    if (length == 0 || length > (1 << 20)) return null;

    // Payload con su propio deadline (el frame llega entero en una sola
    // escritura, así que no debería tardar).
    _payloadBuffer ??= malloc<Uint8>(1 << 20);
    final buffer = _payloadBuffer!;
    final view = buffer.asTypedList(length);
    final payloadDeadline = DateTime.now().add(const Duration(seconds: 5));
    var pOffset = 0;
    while (pOffset < length) {
      final n = _readSome(view, pOffset, length - pOffset);
      if (n == null) {
        closedByPeer = true;
        return null;
      }
      if (n == 0) {
        if (DateTime.now().isAfter(payloadDeadline)) return null;
        sleep(const Duration(milliseconds: 10));
        continue;
      }
      pOffset += n;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(view)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    return (opcode: DiscordOpcode.fromValue(opcode), payload: payload);
  }

  /// Una llamada ReadFile no bloqueante con poll: devuelve `null` si el
  /// pipe se cerró, `0` si no hay datos, o el número de bytes leídos.
  int? _readSome(Uint8List buffer, int offset, int maxBytes) {
    final ptr = malloc<Uint8>(maxBytes);
    final bytesRead = malloc<Int32>();
    try {
      final ok = _readFile(
        _handle,
        ptr.cast<Void>(),
        maxBytes,
        bytesRead,
        nullptr,
      );
      if (ok == 0) {
        final err = _getLastError();
        // ERROR_NO_DATA (232) / ERROR_PIPE_LISTENING (536) → sin datos.
        if (err == 232 || err == 536) return 0;
        return null; // pipe roto
      }
      final n = bytesRead.value;
      if (n > 0) buffer.setRange(offset, offset + n, ptr.asTypedList(n));
      return n;
    } finally {
      malloc.free(ptr);
      malloc.free(bytesRead);
    }
  }

  /// Escribe un frame completo.
  void writeFrame(DiscordOpcode opcode, Map<String, dynamic> payload) {
    writeRawBytes(DiscordIpcCodec.encodeFrame(opcode, payload));
  }

  /// Escribe bytes crudos en el pipe (síncrono).
  void writeRawBytes(List<int> bytes) {
    final ptr = malloc<Uint8>(bytes.length);
    final written = malloc<Int32>();
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final ok = _writeFile(
          _handle,
          (ptr + offset).cast<Void>(),
          bytes.length - offset,
          written,
          nullptr,
        );
        if (ok == 0) return;
        final n = written.value;
        if (n <= 0) return;
        offset += n;
      }
    } finally {
      malloc.free(ptr);
      malloc.free(written);
    }
  }

  void close() {
    _closeHandle(_handle);
    if (_payloadBuffer != null) {
      malloc.free(_payloadBuffer!);
      _payloadBuffer = null;
    }
  }
}
