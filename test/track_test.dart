import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/track.dart';

void main() {
  group('Track.fromYtDlp', () {
    test('parsea metadatos básicos', () {
      final track = Track.fromYtDlp({
        'id': 'abc123',
        'title': 'Mi canción',
        'channel': 'Mi Canal',
        'duration': 214,
      });

      expect(track.id, 'abc123');
      expect(track.title, 'Mi canción');
      expect(track.artist, 'Mi Canal');
      expect(track.duration, const Duration(seconds: 214));
      expect(track.youtubeUrl, 'https://www.youtube.com/watch?v=abc123');
    });

    test('usa uploader como artista si no hay channel', () {
      final track = Track.fromYtDlp({
        'id': 'xyz',
        'title': 'Tema',
        'uploader': 'Artista Real',
      });

      expect(track.artist, 'Artista Real');
    });

    test('tolera duración ausente', () {
      final track = Track.fromYtDlp({'id': 'no-dur', 'title': 'Sin duración'});
      expect(track.duration, isNull);
    });

    test('elige el thumbnail de mayor resolución', () {
      final track = Track.fromYtDlp({
        'id': 't1',
        'title': 'T',
        'thumbnails': [
          {'url': 'http://low', 'width': 120},
          {'url': 'http://high', 'width': 480},
          {'url': 'http://medium', 'width': 240},
        ],
      });

      expect(track.thumbnailUrl, 'http://high');
    });

    test('sin thumbnails deja thumbnailUrl null', () {
      final track = Track.fromYtDlp({'id': 't2', 'title': 'T'});
      expect(track.thumbnailUrl, isNull);
    });

    test('limpia tags de publicación del título', () {
      final track = Track.fromYtDlp({
        'id': 't3',
        'title': 'Mi Canción (Official Video)',
        'channel': 'Canal',
      });
      expect(track.title, 'Mi Canción');
    });

    test('lee el álbum cuando yt-dlp lo aporta', () {
      final track = Track.fromYtDlp({
        'id': 't4',
        'title': 'Tema',
        'channel': 'Artista',
        'album': 'El Álbum',
      });
      expect(track.album, 'El Álbum');
    });
  });

  group('Track.copyWith', () {
    test('copia sin perder id', () {
      final original = Track.fromYtDlp({'id': 'c1', 'title': 'Antes'});
      final updated = original.copyWith(title: 'Después');

      expect(updated.id, 'c1');
      expect(updated.title, 'Después');
      expect(original.title, 'Antes');
    });

    test('actualiza el álbum', () {
      final original = Track(id: 'c2', title: 'T', artist: 'A');
      final updated = original.copyWith(album: 'Discovery');
      expect(updated.album, 'Discovery');
      expect(original.album, isNull);
    });
  });
}
