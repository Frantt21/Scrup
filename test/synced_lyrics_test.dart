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
}
