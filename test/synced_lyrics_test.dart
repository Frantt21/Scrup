import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/synced_lyrics.dart';

void main() {
  group('LyricLine.fromLRC', () {
    test('parsea timestamp y texto', () {
      final line = LyricLine.fromLRC('[01:23.45] Hola mundo');
      expect(line.timestamp.inMinutes, 1);
      expect(line.timestamp.inSeconds, 83);
      expect(line.timestamp.inMilliseconds, 83450);
      expect(line.text, 'Hola mundo');
      expect(line.words, isNull);
    });

    test('parsea palabras con timestamps (SyncLRC karaoke)', () {
      final line = LyricLine.fromLRC(
        '[00:01.00]<00:01.00>One <00:01.50>More <00:02.00>Time',
      );
      expect(line.text, 'One More Time');
      expect(line.words, isNotNull);
      expect(line.words, hasLength(3));
      expect(line.words![0].text, 'One');
      expect(line.words![0].timestamp.inMilliseconds, 1000);
      expect(line.words![1].text, 'More');
      expect(line.words![1].timestamp.inMilliseconds, 1500);
      expect(line.words![2].text, 'Time');
      expect(line.words![2].timestamp.inMilliseconds, 2000);
    });

    test(
        'fusiona sílabas de una misma palabra (convención Apple: 1 espacio '
        'intra-palabra, ≥2 entre palabras)', () {
      // Ejemplo real: «stalkeándote» viene partida en «stalkeándo» + «te.»
      final line = LyricLine.fromLRC(
        '[00:24.04] <00:24.04>Me  <00:24.16>paso  '
        '<00:24.51>stalkeándo <00:25.35>te.',
      );
      expect(line.text, 'Me paso stalkeándote.');
      expect(line.words, hasLength(3));
      expect(line.words![2].text, 'stalkeándote.');
      // La palabra fusionada conserva el timestamp de su PRIMERA sílaba.
      expect(line.words![2].timestamp.inMilliseconds, 24510);
    });

    test('fusiona infinitivo + enclítico vía convención de la CANCIÓN', () {
      // La línea «dar te?» no tiene ningún doble espacio por sí sola: la
      // evidencia de la primera línea fuerza la fusión en todo el archivo.
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '[00:20.00] <00:20.00>Una  <00:20.50>vez  <00:21.00>más\n'
            '[00:41.70] <00:41.70>dar <00:42.67>te?',
      );
      expect(lyrics.lines[0].words!.map((w) => w.text).toList(),
          ['Una', 'vez', 'más']);
      expect(lyrics.lines[1].text, 'darte?');
      expect(lyrics.lines[1].words, hasLength(1));
      expect(lyrics.lines[1].words!.single.text, 'darte?');
      expect(lyrics.lines[1].words!.single.timestamp.inMilliseconds, 41700);
    });

    test('sin convención en el archivo, los espacios simples separan palabras',
        () {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '[00:01.00]<00:01.00>One <00:01.50>More <00:02.00>Time',
      );
      expect(lyrics.lines.single.words!.map((w) => w.text).toList(),
          ['One', 'More', 'Time']);
    });

    test('tags pegados sin espacio también se fusionan', () {
      final line = LyricLine.fromLRC(
        '[00:05.00] <00:05.00>Hell<00:05.40>o  <00:06.00>world',
      );
      expect(line.words!.map((w) => w.text).toList(), ['Hello', 'world']);
    });

    test('ignora líneas con formato inválido en SyncedLyrics.fromLRC', () {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '''
[00:00.00] Intro
Línea sin timestamp
[00:05.00] Segunda
''',
      );
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines[0].text, 'Intro');
      expect(lyrics.lines[1].text, 'Segunda');
    });
  });

  group('SyncedLyrics', () {
    test('ordena por timestamp y encuentra la línea actual', () {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '''
[00:05.00] Segunda
[00:00.00] Primera
[00:10.00] Tercera
''',
      );
      expect(lyrics.lines.map((l) => l.text).toList(), [
        'Primera',
        'Segunda',
        'Tercera',
      ]);
      // Con el adelanto de 500ms del índice, al inicio ya apunta a la
      // primera línea (como forawn).
      expect(lyrics.getCurrentLineIndex(Duration.zero), 0);
      // A los 3s → Primera (3.5s con el adelanto, sigue < 5s)
      expect(lyrics.getCurrentLineIndex(const Duration(seconds: 3)), 0);
      // A los 7s → Segunda
      expect(lyrics.getCurrentLineIndex(const Duration(seconds: 7)), 1);
    });

    test('toLRC redondea correctamente', () {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '[01:02.03] Línea',
      );
      expect(lyrics.toLRC(), '[01:02.03] Línea');
      expect(lyrics.hasLyrics, isTrue);
      expect(lyrics.lineCount, 1);
    });
  });

  group('SyncedLyrics.fromTtml', () {
    test('parsea líneas y palabras de Unison richsync', () {
      const ttml = '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="0:13.532" end="0:20.172">'
          '<span begin="0:13.532">I</span> '
          '<span begin="0:13.930">know</span> '
          '<span begin="0:14.463">you</span>'
          '</p>'
          '<p begin="0:21.000" end="0:24.000">'
          '<span begin="00:00:21.000">Second</span> '
          '<span begin="00:00:22.500">line</span>'
          '</p>'
          '</div></body></tt>';
      final lyrics = SyncedLyrics.fromTtml(
        songTitle: 'Tema',
        artist: 'Artista',
        ttmlContent: ttml,
      );
      expect(lyrics.lines, hasLength(2));
      // Reloj M:SS.mmm
      expect(lyrics.lines[0].timestamp.inMilliseconds, 13532);
      expect(lyrics.lines[0].text, 'I know you');
      expect(lyrics.lines[0].words, hasLength(3));
      expect(lyrics.lines[0].words![1].timestamp.inMilliseconds, 13930);
      // Reloj HH:MM:SS.mmm
      expect(lyrics.lines[1].words![0].timestamp.inMilliseconds, 21000);
    });

    test('ordenar palabras desordenadas (coros de fondo anidados)', () {
      const ttml = '<tt><body><div>'
          '<p begin="0:10.000" end="0:14.000">'
          '<span begin="0:12.000">main</span>'
          '<span ttm:role="x-bg"><span begin="0:10.500">bg</span></span>'
          '</p>'
          '</div></body></tt>';
      final lyrics = SyncedLyrics.fromTtml(
        songTitle: 'Tema',
        artist: 'Artista',
        ttmlContent: ttml,
      );
      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines[0].words!.map((w) => w.text).toList(), ['bg', 'main']);
    });
  });

  group('getCurrentLineIndex con líneas karaoke', () {
    SyncedLyrics buildKaraoke() {
      LyricLine line(int seconds) => LyricLine(
            timestamp: Duration(seconds: seconds),
            text: 'l$seconds',
            words: [
              KaraokeWord(timestamp: Duration(seconds: seconds), text: 'l'),
            ],
          );
      return SyncedLyrics(
        songTitle: 'Tema',
        artist: 'Artista',
        lines: [line(5), line(10)],
      );
    }

    test('sin adelanto entre líneas karaoke (la palabra termina de pintarse)', () {
      final lyrics = buildKaraoke();
      // A 9.7s la línea actual SIGUE siendo la primera: el adelanto de
      // 500ms no aplica a líneas con timestamps por palabra.
      expect(
        lyrics.getCurrentLineIndex(const Duration(milliseconds: 9700)),
        0,
      );
      // A los 10s exactos pasa a la segunda.
      expect(lyrics.getCurrentLineIndex(const Duration(seconds: 10)), 1);
    });

    test('el adelanto se mantiene en líneas solo de línea', () {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: 'Tema',
        artist: 'Artista',
        lrcContent: '[00:05.00] A\n[00:10.00] B',
      );
      // A 9.7s ya apunta a B (9.7 + 0.5 >= 10).
      expect(
        lyrics.getCurrentLineIndex(const Duration(milliseconds: 9700)),
        1,
      );
    });
  });
}
