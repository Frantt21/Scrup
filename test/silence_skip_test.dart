import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/services/silence_skip_service.dart';

void main() {
  group('SilenceSkipService.parseSilences', () {
    test('parsea huecos del formato real de silencedetect', () {
      const output = '''
[silencedetect @ 0x600001a70000] silence_start: 275.183375
[silencedetect @ 0x600001a70000] silence_end: 279.742417 | silence_duration: 4.559042
[silencedetect @ 0x600001a70000] silence_start: 310
[silencedetect @ 0x600001a70000] silence_end: 313.25 | silence_duration: 3.25
''';
      final gaps = SilenceSkipService.parseSilences(output);
      expect(gaps.length, 2);
      expect(gaps[0].start.inMilliseconds, 275183);
      expect(gaps[0].end.inMilliseconds, 279742);
      expect(gaps[1].start.inSeconds, 310);
      expect(gaps[1].end.inMilliseconds, 313250);
    });

    test('clampa el silence_start negativo (silencio desde 0) a cero', () {
      const output = '''
[silencedetect @ 0x0] silence_start: -0.031190
[silencedetect @ 0x0] silence_end: 3.538 | silence_duration: 3.569
''';
      final gaps = SilenceSkipService.parseSilences(output);
      expect(gaps.length, 1);
      expect(gaps[0].start, Duration.zero);
      expect(gaps[0].end.inMilliseconds, 3538);
    });

    test('descarta un silence_start sin fin (silencio hasta EOF)', () {
      const output = '''
[silencedetect @ 0x0] silence_start: 12.04
[silencedetect @ 0x0] silence_end: 15.06 | silence_duration: 3.02
[silencedetect @ 0x0] silence_start: 300.5
''';
      final gaps = SilenceSkipService.parseSilences(output);
      expect(gaps.length, 1);
      expect(gaps[0].start.inSeconds, 12);
    });

    test('sin silencios devuelve lista vacía', () {
      const output = '''
Input #0, webm, from 'test.webm':
frame= 1234 fps=0.0 q=-0.0 Lsize=   12345kB
''';
      expect(SilenceSkipService.parseSilences(output), isEmpty);
    });

    test('los huecos reportan contains correctamente', () {
      const gap = SilenceGap(Duration(seconds: 10), Duration(seconds: 14));
      expect(gap.contains(const Duration(seconds: 9)), isFalse);
      expect(gap.contains(const Duration(seconds: 10)), isTrue);
      expect(gap.contains(const Duration(seconds: 13)), isTrue);
      expect(gap.contains(const Duration(seconds: 14)), isFalse);
    });
  });

  group('SilenceSkipService.parseSkipSegments', () {
    test('parsea la respuesta real de skipSegments (music_offtopic)', () {
      const body = '''
[{"category":"music_offtopic","actionType":"skip","segment":[0,56.03668],
"UUID":"6fc5029710adb642ab604baa6bbe3d2d5a94d3b57f51e13062262af53bc2f16f",
"videoDuration":0,"locked":0,"votes":4,"description":""},
{"category":"music_offtopic","actionType":"skip","segment":[147.754,157.089],
"UUID":"0973989df8abf2d7b62597d71563a096cee95454958caf6720c33159f3ddc2146",
"videoDuration":279.761,"locked":0,"votes":1,"description":""}]
''';
      final gaps = SilenceSkipService.parseSkipSegments(body);
      expect(gaps.length, 2);
      expect(gaps[0].start, Duration.zero);
      expect(gaps[0].end.inMilliseconds, 56036);
      expect(gaps[1].start.inMilliseconds, 147754);
      expect(gaps[1].end.inMilliseconds, 157089);
    });

    test('ignora actionType distinto de skip y segmentos diminutos', () {
      const body = '''
[{"category":"poi_highlight","actionType":"poi","segment":[10,12]},
{"category":"filler","actionType":"skip","segment":[30,30.2]},
{"category":"sponsor","actionType":"skip","segment":[40,45]}]
''';
      final gaps = SilenceSkipService.parseSkipSegments(body);
      expect(gaps.length, 1);
      expect(gaps[0].start.inSeconds, 40);
      expect(gaps[0].end.inSeconds, 45);
    });

    test('JSON inválido o vacío devuelve lista vacía', () {
      expect(SilenceSkipService.parseSkipSegments('Not Found'), isEmpty);
      expect(SilenceSkipService.parseSkipSegments('{}'), isEmpty);
      expect(SilenceSkipService.parseSkipSegments('[]'), isEmpty);
    });
  });
}
