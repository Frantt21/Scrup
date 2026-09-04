import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:scrup/core/track.dart';
import 'package:scrup/services/media_kit_backend.dart';
import 'package:scrup/services/player_service.dart';

/// Genera un WAV mudo de [seconds] segundos (16-bit PCM mono 8kHz) para que
/// media_kit pueda abrir una fuente local real en el test.
Uint8List _silentWav(int seconds) {
  final sampleRate = 8000;
  final samples = sampleRate * seconds;
  final dataSize = samples * 2; // 16-bit mono
  final bytes = BytesBuilder();
  void str(String s) => bytes.add(s.codeUnits);
  void u32(int v) => bytes.add([
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ]);
  void u16(int v) => bytes.add([v & 0xFF, (v >> 8) & 0xFF]);
  str('RIFF');
  u32(36 + dataSize);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits
  str('data');
  u32(dataSize);
  for (var i = 0; i < samples; i++) {
    u16(0);
  }
  return bytes.toBytes();
}

void main() {
  late File wav;
  late PlayerService player;
  final enriched = <Track>[];

  setUp(() async {
    MediaKit.ensureInitialized();
    wav = File(
      '${Directory.systemTemp.path}/scrup_meta_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await wav.writeAsBytes(_silentWav(30));
    enriched.clear();
    player = PlayerService(
      audioBackend: MediaKitBackend(),
      resolveSource: (track) async => PlayableSource(wav.path, isLocal: true),
      onEnriched: (track) async => enriched.add(track),
    );
  });

  tearDown(() async {
    await player.dispose();
    if (await wav.exists()) await wav.delete();
  });

  group('PlayerService.updateCurrentMetadata', () {
    test(
      'actualiza la cola y la pista actual, y persiste vía onEnriched',
      () async {
        final t1 = Track(id: 'a', title: 'Uno', artist: 'Artista A');
        final t2 = Track(id: 'b', title: 'Dos', artist: 'Artista B');
        await player.playQueue([t1, t2]);
        expect(player.currentTrackValue?.id, 'a');

        final updated = t1.copyWith(
          title: 'Uno Editado',
          artist: 'Artista A2',
          album: 'Álbum Nuevo',
          thumbnailUrl: 'https://example.com/cover.jpg',
        );
        await player.updateCurrentMetadata(updated);

        // Cola: la entrada con el mismo id se reemplazó en su lugar.
        expect(player.queue.value.length, 2);
        expect(player.queue.value[0].id, 'a');
        expect(player.queue.value[0].title, 'Uno Editado');
        expect(player.queue.value[0].album, 'Álbum Nuevo');
        expect(
          player.queue.value[0].thumbnailUrl,
          'https://example.com/cover.jpg',
        );
        // La otra pista no se toca.
        expect(player.queue.value[1].id, 'b');
        expect(player.queue.value[1].title, 'Dos');

        // UI: la pista en reproducción se republica con la metadata nueva.
        expect(player.currentTrackValue?.id, 'a');
        expect(player.currentTrackValue?.title, 'Uno Editado');
        expect(player.currentTrackValue?.artist, 'Artista A2');

        // Persistencia: onEnriched recibió el track actualizado (mismo id).
        expect(enriched, hasLength(1));
        expect(enriched.single.id, 'a');
        expect(enriched.single.title, 'Uno Editado');
        expect(enriched.single.album, 'Álbum Nuevo');
      },
    );

    test('no toca la cola si la pista no está en ella', () async {
      await player.playQueue([
        Track(id: 'a', title: 'Uno', artist: 'Artista A'),
        Track(id: 'b', title: 'Dos', artist: 'Artista B'),
      ]);

      final outside = Track(
        id: 'zz',
        title: 'Otra',
        artist: 'Otro',
      ).copyWith(title: 'Otra Editada');
      await player.updateCurrentMetadata(outside);

      // La cola y la pista actual siguen intactas (ids distintos).
      expect(player.queue.value.map((t) => t.id).toList(), ['a', 'b']);
      expect(player.queue.value[0].title, 'Uno');
      expect(player.currentTrackValue?.id, 'a');
      // La persistencia es best-effort: onEnriched no debe recibir una pista
      // que no es la actual ni está en la cola.
      expect(enriched, isEmpty);
    });

    test('no publica en la UI si la pista ya no es la actual', () async {
      final t1 = Track(id: 'a', title: 'Uno', artist: 'Artista A');
      final t2 = Track(id: 'b', title: 'Dos', artist: 'Artista B');
      await player.playQueue([t1, t2]);
      // Saltar a la segunda: la cola mantiene ambas, pero la actual es 'b'.
      await player.playQueueAt(1);
      expect(player.currentTrackValue?.id, 'b');

      // Editar 'a' (sigue en la cola, ya no es la actual).
      final updatedA = t1.copyWith(title: 'Uno Editado');
      await player.updateCurrentMetadata(updatedA);

      // La cola se actualiza...
      expect(player.queue.value[0].title, 'Uno Editado');
      // ...pero la UI sigue mostrando 'b' (no se publica una pista no actual).
      expect(player.currentTrackValue?.id, 'b');
      expect(player.currentTrackValue?.title, 'Dos');
      // La persistencia sí corre (es el camino del enriquecimiento).
      expect(enriched.single.id, 'a');
    });
  });
}
