import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../core/track.dart';
import 'tables.dart';

part 'database.g.dart';

/// Modelo de dominio para una playlist (evita filtrar DataClass de drift).
class Playlist {
  final int id;
  final String name;
  final DateTime createdAt;
  const Playlist({required this.id, required this.name, required this.createdAt});
}

@DriftDatabase(tables: [Tracks, History, Playlists, PlaylistTracks])
class AppDatabase extends _$AppDatabase {
  /// [executor] permite inyectar una base en memoria en los tests.
  AppDatabase({QueryExecutor? executor})
      : super(executor ?? driftDatabase(name: 'scrup'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(playlists);
            await m.createTable(playlistTracks);
          }
        },
      );

  // ---------------------------------------------------------------- cache
  /// Guarda (o actualiza) los metadatos de una pista. Nunca guardamos la URL
  /// de audio porque expira.
  Future<void> cacheTrack(Track track) async {
    await into(tracks).insertOnConflictUpdate(
      TracksCompanion.insert(
        id: track.id,
        title: track.title,
        artist: Value(track.artist),
        durationSeconds: Value(track.duration?.inSeconds),
        thumbnailUrl: Value(track.thumbnailUrl),
      ),
    );
  }

  /// Devuelve los metadatos cacheados de una pista, si existen.
  Future<Track?> getCachedTrack(String id) async {
    final row = await (select(tracks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return _trackFromRow(row);
  }

  /// Últimas canciones reproducidas (para la pantalla principal sin conexión).
  ///
  /// Deduplica por track id: cada canción aparece una sola vez, usando la
  /// reproducción más reciente. El historial está acotado por el pruning
  /// (60 días), así que traemos todas las filas y deduplicamos en memoria.
  Stream<List<Track>> watchRecentlyPlayed({int limit = 30}) {
    final query = (select(history)
          ..orderBy([(h) => OrderingTerm.desc(h.playedAt)]))
        .join([innerJoin(tracks, tracks.id.equalsExp(history.trackId))]);

    return query.watch().map((rows) {
      final seen = <String>{};
      final result = <Track>[];
      for (final row in rows) {
        final track = _trackFromRow(row.readTable(tracks));
        if (seen.add(track.id)) {
          result.add(track);
          if (result.length >= limit) break;
        }
      }
      return result;
    });
  }

  // ------------------------------------------------------------- historial
  /// Registra una reproducción (marca lastPlayed, incrementa playCount y
  /// añade una fila al historial).
  Future<void> recordPlay(Track track) async {
    await cacheTrack(track);
    await (update(tracks)..where((t) => t.id.equals(track.id))).write(
      TracksCompanion(lastPlayed: Value(DateTime.now())),
    );
    await customUpdate(
      'UPDATE tracks SET play_count = play_count + 1 WHERE id = ?',
      variables: [Variable(track.id)],
      updates: {tracks},
    );
    await into(history).insert(
      HistoryCompanion.insert(trackId: track.id, playedAt: DateTime.now()),
    );
    // Pruning: mantener solo los últimos 60 días de historial
    await (delete(history)
          ..where((h) => h.playedAt.isSmallerThanValue(
                DateTime.now().subtract(const Duration(days: 60)),
              )))
        .go();
  }

  // ------------------------------------------------------------ playlists
  Stream<List<Playlist>> watchPlaylists() {
    final query = select(playlists)
      ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]);
    return query.watch().map((rows) => rows
        .map((r) => Playlist(id: r.id, name: r.name, createdAt: r.createdAt))
        .toList());
  }

  /// Crea una playlist y devuelve su id.
  Future<int> createPlaylist(String name) async {
    final id = await into(playlists).insert(
      PlaylistsCompanion.insert(name: name),
    );
    return id;
  }

  Future<void> deletePlaylist(int id) async {
    await (delete(playlistTracks)..where((pt) => pt.playlistId.equals(id)))
        .go();
    await (delete(playlists)..where((p) => p.id.equals(id))).go();
  }

  Future<Playlist?> getPlaylist(int id) async {
    final row = await (select(playlists)..where((p) => p.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Playlist(id: row.id, name: row.name, createdAt: row.createdAt);
  }

  /// Canciones de una playlist (con metadatos cacheados), en orden.
  Stream<List<Track>> watchPlaylistTracks(int playlistId) {
    final query = (select(playlistTracks)
          ..where((pt) => pt.playlistId.equals(playlistId))
          ..orderBy([(pt) => OrderingTerm.asc(pt.position)]))
        .join([innerJoin(tracks, tracks.id.equalsExp(playlistTracks.trackId))]);

    return query.watch().map((rows) {
      return rows.map((row) => _trackFromRow(row.readTable(tracks))).toList();
    });
  }

  /// Añade una canción al final de una playlist (no duplica).
  Future<void> addToPlaylist(int playlistId, Track track) async {
    await cacheTrack(track);
    final existing = await (select(playlistTracks)
          ..where(
            (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(track.id),
          ))
        .get();
    if (existing.isNotEmpty) return;

    final maxPos = await (selectOnly(playlistTracks)
          ..addColumns([playlistTracks.position.max()])
          ..where(playlistTracks.playlistId.equals(playlistId)))
        .map((row) => row.read(playlistTracks.position.max()))
        .getSingle();
    final nextPosition = (maxPos ?? 0) + 1;

    await into(playlistTracks).insert(
      PlaylistTracksCompanion.insert(
        playlistId: playlistId,
        trackId: track.id,
        position: nextPosition,
      ),
    );
  }

  Future<void> removeFromPlaylist(int playlistId, String trackId) async {
    await (delete(playlistTracks)
          ..where(
            (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId),
          ))
        .go();
  }

  // ------------------------------------------------------------- helpers
  Track _trackFromRow(TrackRow row) {
    return Track(
      id: row.id,
      title: row.title,
      artist: row.artist,
      duration: row.durationSeconds != null
          ? Duration(seconds: row.durationSeconds!)
          : null,
      thumbnailUrl: row.thumbnailUrl,
    );
  }

}

