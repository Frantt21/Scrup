import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scrup/services/audio_cache_service.dart';
import 'package:scrup/services/ytdlp_service.dart';

/// Falso yt-dlp que escribe archivos locales sin tocar red.
class _FakeYtDlp extends YtDlpService {
  int downloadCalls = 0;
  int fileSize = 4000;

  @override
  Future<String> downloadAudio(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    downloadCalls++;
    final file = File(p.join(outputDir, '$videoId.m4a'));
    file.writeAsBytesSync(List.filled(fileSize, 7));
    onProgress?.call(0.5);
    onProgress?.call(1.0);
    return file.path;
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
    await tmp.delete(recursive: true);
  });

  test('cachedPath: null sin cache, ruta si el archivo existe', () async {
    expect(await cache.cachedPath('abc123'), isNull);

    final f = File(p.join(tmp.path, 'abc123.m4a'));
    f.writeAsBytesSync([1, 2, 3]);
    final path = await cache.cachedPath('abc123');
    expect(path, f.path);
  });

  test('ensure descarga una sola vez y luego sirve del caché', () async {
    final first = await cache.ensure('abc123', title: 'Tema');
    expect(ytdlp.downloadCalls, 1);
    expect(File(first).existsSync(), isTrue);

    // Segunda llamada: sin nueva descarga, misma ruta.
    final second = await cache.ensure('abc123');
    expect(ytdlp.downloadCalls, 1);
    expect(second, first);
  });

  test('ensure deduplica descargas concurrentes del mismo video', () async {
    final results = await Future.wait([
      cache.ensure('abc123'),
      cache.ensure('abc123'),
      cache.ensure('abc123'),
    ]);
    expect(ytdlp.downloadCalls, 1);
    expect(results.toSet().length, 1);
    expect(File(results.first).existsSync(), isTrue);
  });

  test('el progreso se notifica durante la descarga', () async {
    final seen = <double?>[];
    cache.progress.addListener(() => seen.add(cache.progress.value));
    await cache.ensure('abc123');
    expect(seen, contains(0.5));
    expect(seen, contains(1.0));
  });

  test('el límite de tamaño elimina los archivos más antiguos (LRU)', () async {
    final smallCache = AudioCacheService(
      ytdlp: ytdlp,
      directoryOverride: tmp,
      maxSizeBytes: 6000, // cabe ~1 archivo de 4000 bytes
    );
    await smallCache.ensure('v1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await smallCache.ensure('v2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await smallCache.ensure('v3');

    // v1 y v2 fueron expulsados por antigüedad; v3 sigue en caché.
    expect(await smallCache.cachedPath('v1'), isNull);
    expect(await smallCache.cachedPath('v2'), isNull);
    expect(await smallCache.cachedPath('v3'), isNotNull);
  });

  test('clear vacía todo el caché', () async {
    await cache.ensure('abc123');
    expect(await cache.cachedPath('abc123'), isNotNull);
    await cache.clear();
    expect(await cache.cachedPath('abc123'), isNull);
  });
}
