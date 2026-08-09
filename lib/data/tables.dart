import 'package:drift/drift.dart';

/// Tabla de canciones cacheadas localmente (metadatos, NO la URL de audio,
/// porque esas URLs expiran).
@DataClassName('TrackRow')
class Tracks extends Table {
  TextColumn get id => text()(); // video id de YouTube
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();

  /// Álbum enriquecido vía Deezer (null si aún no se ha enriquecido).
  TextColumn get album => text().nullable()();
  DateTimeColumn get lastPlayed => dateTime().nullable()();
  IntColumn get playCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Historial de reproducción (relaciona pista + timestamp).
@DataClassName('HistoryRow')
class History extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackId => text().references(Tracks, #id)();
  DateTimeColumn get playedAt => dateTime()();
}

/// Playlist creada por el usuario.
@DataClassName('PlaylistRow')
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Portada de la playlist (URL del artwork de una de sus canciones, o
  /// null si aún no tiene).
  TextColumn get coverUrl => text().nullable()();
}

/// Relación N:M entre playlists y canciones, con posición de orden.
@DataClassName('PlaylistTrackRow')
class PlaylistTracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId => integer().references(Playlists, #id)();
  TextColumn get trackId => text().references(Tracks, #id)();
  IntColumn get position => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {playlistId, trackId},
  ];
}
