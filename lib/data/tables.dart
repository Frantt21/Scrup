import 'package:drift/drift.dart';

/// Locally cached songs (metadata only, NOT the audio URL, because those URLs expire).
@DataClassName('TrackRow')
class Tracks extends Table {
  TextColumn get id => text()(); // YouTube video id
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();

  /// Album enriched via Deezer (null until it has been enriched).
  TextColumn get album => text().nullable()();
  DateTimeColumn get lastPlayed => dateTime().nullable()();
  IntColumn get playCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Playback history (links track + timestamp).
@DataClassName('HistoryRow')
class History extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackId => text().references(Tracks, #id)();
  DateTimeColumn get playedAt => dateTime()();
}

/// User-created playlist.
@DataClassName('PlaylistRow')
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Playlist cover (URL of the artwork of one of its songs, or null if none yet).
  TextColumn get coverUrl => text().nullable()();

  /// Optional description written by the user.
  TextColumn get description => text().nullable()();

  /// Special Favorites playlist (always last, cannot be deleted).
  BoolColumn get isFavorites => boolean().withDefault(const Constant(false))();

  /// Last time the playlist was played (for the home recent playlists section).
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
}

/// Cached lyrics for a song (synced LRC).
@DataClassName('LyricsRow')
class Lyrics extends Table {
  TextColumn get id => text()(); // normalized title_artist
  TextColumn get lrcContent => text()(); // full LRC content
  BoolColumn get isNotFound => boolean().withDefault(const Constant(false))();
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Artwork palette cache: the player accent (1 color) and the fullscreen background trio (3 colors), by cover URL.
///
/// Replaces the former plain JSON: incremental writes (INSERT OR REPLACE per entry), no full rewrite, and total load does not grow unbounded. [usedAt] orders LRU trimming.
@DataClassName('PaletteRow')
class PaletteCache extends Table {
  TextColumn get id => text()(); // artwork URL
  IntColumn get c1 => integer()(); // ARGB accent / first color
  IntColumn get c2 => integer().nullable()(); // ARGB (trio)
  IntColumn get c3 => integer().nullable()(); // ARGB (trio)
  DateTimeColumn get usedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
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
