import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scrup/services/audio_cache_service.dart';
import 'package:scrup/services/ytdlp_service.dart';

/// Falso yt-dlp con reproducción progresiva: crea un `.part` reproducible al
/// instante y lo renombra al archivo final cuando el test llama a
/// [finishPending] (sin timers sueltos que sobrevivan al test).
class _FakeYtDlp extends YtDlpService {
  int startCalls = 0;
  int fileSize = 4000;

  /// Si es true, la siguiente descarga falla (prueba la limpieza del .part).
  bool failNext = false;

  /// Cierres pendientes de "completar la descarga" (renombrar .part → final).
  final List<void Function()> _pendingFinish = [];

  @override
  Future<StreamingDownload> startStreaming(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    startCalls++;
    final partial = File(p.join(outputDir, '$videoId.webm.part'));
    partial.writeAsBytesSync(List.filled(4096, 7));

    if (failNext) {
      final err = Completer<String>();
      // Marcar el error como atendido de inmediato. El servicio real completa
      // el error después de que los listeners se adjunten (proceso que falla
      // más tarde); el fake lo hace de forma síncrona, antes de que nadie
      // escuche, y sin este probe Dart lo reportaría como error no manejado.
      err.future.catchError((_) => '');
      err.completeError(YtDlpException('fallo simulado'));
      return StreamingDownload(
        playablePath: err.future,
        finalPath: err.future,
        cancel: () {},
      );
    }

    // El `.part` es reproducible al instante.
    onProgress?.call(0.5);
    final playable = Completer<String>()..complete(partial.path);
    final done = Completer<String>();
    // La descarga "completa" cuando el test lo pide: renombra al final.
    _pendingFinish.add(() {
      final finalFile = File(p.join(outputDir, '$videoId.webm'));
      finalFile.writeAsBytesSync(List.filled(fileSize, 7));
      try {
        partial.deleteSync();
      } catch (_) {}
      onProgress?.call(1.0);
      if (!done.isCompleted) done.complete(finalFile.path);
    });
    return StreamingDownload(
      playablePath: playable.future,
      finalPath: done.future,
      cancel: () {},
    );
  }

  /// Termina todas las descargas pendientes (renombra el .part al final).
  void finishPending() {
    final pending = List.of(_pendingFinish);
    _pendingFinish.clear();
    for (final f in pending) {
      f();
    }
  }
}

void main() {
  late Directory tmp;
  late _FakeYtDlp ytdlp;
  late AudioCacheService cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrup_cache_test_');
    ytdlp = _FakeYtDlp();
    cache = AudioCacheService(ytdlp: ytdlp, directoryOverride: tmp);
  });

  tearDown(() async {
    // Terminar cualquier descarga pendiente y dejar que las cadenas de
    // limpieza se asienten antes de borrar el directorio.
    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('cachedPath: null sin cache, ruta si el archivo existe', () async {
    expect(await cache.cachedPath('abc123'), isNull);

    final f = File(p.join(tmp.path, 'abc123.m4a'));
    f.writeAsBytesSync([1, 2, 3]);
    final path = await cache.cachedPath('abc123');
    expect(path, f.path);
  });

  test(
    'ensureStreaming devuelve el .part reproducible sin esperar el final',
    () async {
      final source = await cache.ensureStreaming('abc123', title: 'Tema');
      expect(source.fromCache, isFalse);
      expect(source.path, endsWith('.part'));
      expect(File(source.path).existsSync(), isTrue);
      expect(ytdlp.startCalls, 1);
    },
  );

  test(
    'la descarga en segundo plano termina en caché y luego es instantánea',
    () async {
      final first = await cache.ensureStreaming('abc123');
      // El .part se reproduce ya; la descarga "termina" al renombrar.
      ytdlp.finishPending();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(await cache.cachedPath('abc123'), isNotNull);
      expect(
        File(first.path).existsSync(),
        isFalse,
        reason: 'el .part ya fue renombrado al archivo final',
      );

      // Segunda reproducción: desde caché, sin nueva descarga.
      final second = await cache.ensureStreaming('abc123');
      expect(second.fromCache, isTrue);
      expect(ytdlp.startCalls, 1);
    },
  );

  test(
    'ensureStreaming deduplica descargas concurrentes del mismo video',
    () async {
      final results = await Future.wait([
        cache.ensureStreaming('abc123'),
        cache.ensureStreaming('abc123'),
        cache.ensureStreaming('abc123'),
      ]);
      expect(ytdlp.startCalls, 1);
      expect(results.map((s) => s.path).toSet().length, 1);
      expect(File(results.first.path).existsSync(), isTrue);
    },
  );

  test('el progreso se notifica durante la descarga', () async {
    final seen = <double?>[];
    cache.progress.addListener(() => seen.add(cache.progress.value));
    await cache.ensureStreaming('abc123');
    expect(seen, contains(0.5));

    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(seen, contains(1.0));
  });

  test('si la descarga falla, se limpia el .part incompleto', () async {
    ytdlp.failNext = true;
    await expectLater(
      cache.ensureStreaming('abc123'),
      throwsA(isA<YtDlpException>()),
    );
    // Dar tiempo al cleanup asíncrono de _trackDownload.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final leftovers = await tmp
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(leftovers, isEmpty);
  });

  test('el límite de tamaño elimina los archivos más antiguos (LRU)', () async {
    final smallCache = AudioCacheService(
      ytdlp: ytdlp,
      directoryOverride: tmp,
      maxSizeBytes: 6000, // cabe ~1 archivo de 4000 bytes
    );
    await smallCache.ensureStreaming('v1');
    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await smallCache.ensureStreaming('v2');
    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await smallCache.ensureStreaming('v3');
    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // v1 y v2 fueron expulsados por antigüedad; v3 sigue en caché.
    expect(await smallCache.cachedPath('v1'), isNull);
    expect(await smallCache.cachedPath('v2'), isNull);
    expect(await smallCache.cachedPath('v3'), isNotNull);
  });

  test('clear vacía todo el caché', () async {
    await cache.ensureStreaming('abc123');
    ytdlp.finishPending();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await cache.cachedPath('abc123'), isNotNull);

    await cache.clear();
    expect(await cache.cachedPath('abc123'), isNull);
  });
}
