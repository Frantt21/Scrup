import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/track.dart';
import 'package:scrup/data/database.dart';

/// Crea una DB en memoria para los tests (sin UI/plugins).
AppDatabase createInMemoryDb() {
  return AppDatabase(executor: NativeDatabase.memory());
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = createInMemoryDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('cache e historial', () {
    test('recordPlay cachea la pista y crea historial', () async {
      final track = Track(
        id: 't1',
        title: 'Canción',
        artist: 'Artista',
        duration: const Duration(seconds: 90),
      );

      await db.recordPlay(track);
      await db.recordPlay(track);

      final cached = await db.getCachedTrack('t1');
      expect(cached, isNotNull);
      expect(cached!.title, 'Canción');
    });

    test(
      'recientes deduplica la misma canción reproducida varias veces',
      () async {
        final track = Track(id: 't1', title: 'Canción', artist: 'Artista');

        await db.recordPlay(track);
        await db.recordPlay(track);
        await db.recordPlay(track);

        // La misma canción 3 veces → aparece una sola vez en recientes
        final recientes = await db.watchRecentlyPlayed().first;
        expect(recientes.length, 1);
        expect(recientes.first.id, 't1');
      },
    );

    test('recientes ordena las canciones distintas por último play', () async {
      final a = Track(id: 'a', title: 'A', artist: 'X');
      final b = Track(id: 'b', title: 'B', artist: 'Y');

      await db.recordPlay(a);
      await db.recordPlay(b);
      await db.recordPlay(a); // 'a' vuelve arriba

      final recientes = await db.watchRecentlyPlayed().first;
      expect(recientes.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('persiste el álbum enriquecido y lo devuelve al leer', () async {
      final track = Track(
        id: 'alb1',
        title: 'One More Time',
        artist: 'Daft Punk',
        album: 'Discovery',
        thumbnailUrl:
            'https://e-cdns-images.dzcdn.net/images/cover/x/500x500.jpg',
      );

      await db.cacheTrack(track);
      final cached = await db.getCachedTrack('alb1');

      expect(cached, isNotNull);
      expect(cached!.album, 'Discovery');
      expect(cached.thumbnailUrl, track.thumbnailUrl);
      expect(cached.title, 'One More Time');
    });

    test(
      'updateTrackMetadata refleja el artwork enriquecido en recientes',
      () async {
        final original = Track(id: 'enr1', title: 'Original', artist: 'YT');
        await db.recordPlay(original);

        final enriched = Track(
          id: 'enr1',
          title: 'Título Deezer',
          artist: 'Artista Real',
          album: 'Álbum',
          thumbnailUrl:
              'https://e-cdns-images.dzcdn.net/images/cover/x/500x500.jpg',
        );
        await db.updateTrackMetadata(enriched);

        final cached = await db.getCachedTrack('enr1');
        expect(cached, isNotNull);
        expect(cached!.title, 'Título Deezer');
        expect(cached.album, 'Álbum');

        // Las recientes reflejan el artwork enriquecido, sin duplicar.
        final recientes = await db.watchRecentlyPlayed().first;
        expect(recientes.length, 1);
        expect(recientes.first.thumbnailUrl, enriched.thumbnailUrl);
        expect(recientes.first.album, 'Álbum');
      },
    );

    test(
      'recordPlay guarda el álbum del track enriquecido en recientes',
      () async {
        final track = Track(
          id: 'alb2',
          title: 'One More Time',
          artist: 'Daft Punk',
          album: 'Discovery',
          thumbnailUrl:
              'https://e-cdns-images.dzcdn.net/images/cover/x/500x500.jpg',
        );

        await db.recordPlay(track);
        final recientes = await db.watchRecentlyPlayed().first;

        expect(recientes.first.album, 'Discovery');
        expect(
          recientes.first.thumbnailUrl,
          'https://e-cdns-images.dzcdn.net/images/cover/x/500x500.jpg',
        );
      },
    );
  });

  group('playlists', () {
    test('crear y listar playlists', () async {
      final id = await db.createPlaylist('Favoritas');
      expect(id, greaterThan(0));

      final playlists = await db.watchPlaylists().first;
      expect(playlists.length, 1);
      expect(playlists.first.name, 'Favoritas');
    });

    test('añadir canción a playlist sin duplicar', () async {
      final playlistId = await db.createPlaylist('Rock');
      final track = Track(id: 'r1', title: 'Riff', artist: 'Banda');

      await db.addToPlaylist(playlistId, track);
      await db.addToPlaylist(playlistId, track); // duplicado → se ignora

      final tracks = await db.watchPlaylistTracks(playlistId).first;
      expect(tracks.length, 1);
      expect(tracks.first.id, 'r1');
    });

    test('setPlaylistCover establece y quita la portada', () async {
      final id = await db.createPlaylist('Portada');
      expect(await db.getPlaylist(id), isNotNull);
      expect((await db.getPlaylist(id))!.coverUrl, isNull);

      await db.setPlaylistCover(id, 'https://img/portada.jpg');
      final playlists = await db.watchPlaylists().first;
      expect(playlists.first.coverUrl, 'https://img/portada.jpg');
      expect((await db.getPlaylist(id))!.coverUrl, 'https://img/portada.jpg');

      // Quitar la portada
      await db.setPlaylistCover(id, null);
      expect((await db.getPlaylist(id))!.coverUrl, isNull);
    });

    test('setPlaylistDescription establece y quita la descripción', () async {
      final id = await db.createPlaylist('Descripción');
      expect((await db.getPlaylist(id))!.description, isNull);

      await db.setPlaylistDescription(id, 'Mis canciones favoritas');
      final playlists = await db.watchPlaylists().first;
      expect(playlists.first.description, 'Mis canciones favoritas');
      expect(
        (await db.getPlaylist(id))!.description,
        'Mis canciones favoritas',
      );

      // Quitar la descripción
      await db.setPlaylistDescription(id, null);
      expect((await db.getPlaylist(id))!.description, isNull);
    });

    test('renamePlaylist cambia el nombre', () async {
      final id = await db.createPlaylist('Antes');
      await db.renamePlaylist(id, 'Después');
      expect((await db.getPlaylist(id))!.name, 'Después');
      final playlists = await db.watchPlaylists().first;
      expect(playlists.first.name, 'Después');
    });

    test('addToPlaylist usa el artwork como portada si no tenía', () async {
      final id = await db.createPlaylist('Auto');
      final track = Track(
        id: 'auto1',
        title: 'Canción',
        artist: 'Artista',
        thumbnailUrl: 'https://img/thumb.jpg',
      );

      await db.addToPlaylist(id, track);
      expect((await db.getPlaylist(id))!.coverUrl, 'https://img/thumb.jpg');

      // Si ya tiene portada, no la sobreescribe con otra canción
      final track2 = Track(
        id: 'auto2',
        title: 'Otra',
        artist: 'Otro',
        thumbnailUrl: 'https://img/other.jpg',
      );
      await db.addToPlaylist(id, track2);
      expect((await db.getPlaylist(id))!.coverUrl, 'https://img/thumb.jpg');
    });

    test('quitar canción de playlist', () async {
      final playlistId = await db.createPlaylist('Mix');
      final track = Track(id: 'm1', title: 'Mix', artist: 'DJ');

      await db.addToPlaylist(playlistId, track);
      await db.removeFromPlaylist(playlistId, 'm1');

      final tracks = await db.watchPlaylistTracks(playlistId).first;
      expect(tracks, isEmpty);
    });

    test('eliminar playlist borra sus canciones', () async {
      final playlistId = await db.createPlaylist('Temporal');

      await db.addToPlaylist(
        playlistId,
        Track(id: 'x1', title: 'X', artist: 'A'),
      );
      await db.deletePlaylist(playlistId);

      final playlists = await db.watchPlaylists().first;
      expect(playlists, isEmpty);
      final tracks = await db.watchPlaylistTracks(playlistId).first;
      expect(tracks, isEmpty);
    });
  });
}
