import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../core/track.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Tracks, History])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'scrup'));

  @override
  int get schemaVersion => 1;

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

  /// Últimas canciones reproducidas (para la pantalla principal sin conexión).
  Stream<List<Track>> watchRecentlyPlayed({int limit = 30}) {
    final query = (select(history)
          ..orderBy([(h) => OrderingTerm.desc(h.playedAt)])
          ..limit(limit))
        .join([innerJoin(tracks, tracks.id.equalsExp(history.trackId))]);

    return query.watch().map((rows) {
      return rows.map((row) {
        final t = row.readTable(tracks);
        return Track(
          id: t.id,
          title: t.title,
          artist: t.artist,
          duration: t.durationSeconds != null
              ? Duration(seconds: t.durationSeconds!)
              : null,
          thumbnailUrl: t.thumbnailUrl,
        );
      }).toList();
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
    await (delete(history)..where((h) => h.playedAt.isSmallerThanValue(
          DateTime.now().subtract(const Duration(days: 60)),
        )))
        .go();
  }

  Future<List<Track>> cachedTracks() async {
    final rows = await (select(tracks)..orderBy([(t) => OrderingTerm.desc(t.lastPlayed)])).get();
    return rows
        .map((r) => Track(
              id: r.id,
              title: r.title,
              artist: r.artist,
              duration: r.durationSeconds != null
                  ? Duration(seconds: r.durationSeconds!)
                  : null,
              thumbnailUrl: r.thumbnailUrl,
            ))
        .toList();
  }
}
