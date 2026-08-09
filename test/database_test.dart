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

    test('recientes deduplica la misma canción reproducida varias veces',
        () async {
      final track = Track(id: 't1', title: 'Canción', artist: 'Artista');

      await db.recordPlay(track);
      await db.recordPlay(track);
      await db.recordPlay(track);

      // La misma canción 3 veces → aparece una sola vez en recientes
      final recientes = await db.watchRecentlyPlayed().first;
      expect(recientes.length, 1);
      expect(recientes.first.id, 't1');
    });

    test('recientes ordena las canciones distintas por último play', () async {
      final a = Track(id: 'a', title: 'A', artist: 'X');
      final b = Track(id: 'b', title: 'B', artist: 'Y');

      await db.recordPlay(a);
      await db.recordPlay(b);
      await db.recordPlay(a); // 'a' vuelve arriba

      final recientes = await db.watchRecentlyPlayed().first;
      expect(recientes.map((t) => t.id).toList(), ['a', 'b']);
    });
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
