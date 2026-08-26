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

  group('Track.hiResThumbnail', () {
    test('ytimg → maxresdefault 1280px', () {
      expect(
        Track.hiResThumbnail('https://i.ytimg.com/vi/abc123/mqdefault.jpg'),
        'https://i.ytimg.com/vi/abc123/maxresdefault.jpg',
      );
    });

    test('googleusercontent (YT Music) → variante a 1200px', () {
      expect(
        Track.hiResThumbnail(
          'https://lh3.googleusercontent.com/XyZ=w544-h544-l90-rj',
        ),
        'https://lh3.googleusercontent.com/XyZ=w1200-h1200',
      );
      expect(
        Track.hiResThumbnail(
          'https://lh5.googleusercontent.com/AbC=s60-fcrop64=1',
        ),
        'https://lh5.googleusercontent.com/AbC=w1200-h1200',
      );
    });

    test('URLs sin variante conocida pasan intactas; null/ vacío → null', () {
      expect(Track.hiResThumbnail(null), isNull);
      expect(Track.hiResThumbnail(''), isNull);
      expect(
        Track.hiResThumbnail('https://example.com/cover.jpg'),
        'https://example.com/cover.jpg',
      );
      // googleusercontent SIN sufijo de tamaño: no tocar.
      expect(
        Track.hiResThumbnail('https://lh3.googleusercontent.com/Raw'),
        'https://lh3.googleusercontent.com/Raw',
      );
    });
  });
}
