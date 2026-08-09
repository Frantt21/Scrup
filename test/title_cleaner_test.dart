import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/title_cleaner.dart';

void main() {
  group('TitleCleaner.clean', () {
    test('quita (Official Video) del final', () {
      expect(
        TitleCleaner.clean('Mi Canción (Official Video)'),
        'Mi Canción',
      );
    });

    test('quita [Official Audio] en medio', () {
      expect(
        TitleCleaner.clean('Mi Canción [Official Audio] 2024'),
        'Mi Canción 2024',
      );
    });

    test('quita | Lyrics como sufijo', () {
      expect(
        TitleCleaner.clean('Mi Canción | Lyrics'),
        'Mi Canción',
      );
    });

    test('quita - Video Oficial como sufijo', () {
      expect(
        TitleCleaner.clean('Mi Canción - Video Oficial'),
        'Mi Canción',
      );
    });

    test('quita múltiples tags', () {
      expect(
        TitleCleaner.clean('Mi Canción (Official Music Video) - 4K HD'),
        'Mi Canción',
      );
    });

    test('quita (Letra)', () {
      expect(
        TitleCleaner.clean('Mi Canción (Letra)'),
        'Mi Canción',
      );
    });

    test('conserva el nombre real y los feats', () {
      expect(
        TitleCleaner.clean('Artista - Canción (feat. Otro)'),
        'Artista - Canción (feat. Otro)',
      );
    });

    test('conserva títulos limpios', () {
      expect(
        TitleCleaner.clean('Daft Punk - One More Time'),
        'Daft Punk - One More Time',
      );
    });

    test('limpia espacios múltiples sobrantes', () {
      expect(
        TitleCleaner.clean('Canción   (Audio)   2024'),
        'Canción 2024',
      );
    });
  });
}
