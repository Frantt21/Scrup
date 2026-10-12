import 'package:drift/drift.dart';

/// Locally cached songs (metadata only, NOT the audio URL, because those URLs expire).
@DataClassName('TrackRow')
class Tracks extends Table {
  TextColumn get id => text()(); // YouTube video id
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();

  /// Álbum enriquecido via Deezer (nulo hasta que se enriquece).
  TextColumn get album => text().nullable()();
  DateTimeColumn get lastPlayed => dateTime().nullable()();
  IntColumn get playCount => integer().withDefault(const Constant(0))();

  /// Canal del artista (UC…), aprendido de InnerTube o del propietario de
  /// la pista; alimenta los avatares del recap.
  TextColumn get artistChannelId => text().nullable()();
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

  /// Portada de la playlist (artwork de una de sus canciones, o nulo).
  TextColumn get coverUrl => text().nullable()();

  /// Descripción opcional del usuario.
  TextColumn get description => text().nullable()();

  /// Playlist especial de Favoritos (siempre al final, no borrable).
  BoolColumn get isFavorites => boolean().withDefault(const Constant(false))();

  /// Última reproducción de la playlist (home "recientes").
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
}  /// Cached lyrics for a song (synced LRC).
@DataClassName('LyricsRow')
class Lyrics extends Table {
  TextColumn get id => text()(); // normalized title_artist
  TextColumn get lrcContent => text()(); // full LRC content
  BoolColumn get isNotFound => boolean().withDefault(const Constant(false))();
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Paleta de artwork: acento del player (1 color) + trio de fondo (3),
/// por URL de portada. Reemplaza al JSON anterior: escrituras parciales,
/// carga en memoria acotada. [usedAt] ordena el recorte LRU.
@DataClassName('PaletteRow')
class PaletteCache extends Table {
  TextColumn get id => text()(); // URL de artwork
  IntColumn get c1 => integer()(); // ARGB acento / primer color
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

/// Artistas visitados: alimenta la fila "Artistas visitados" de home.
/// Una fila por artista; volver a abrirlo repuebla el timestamp.
@DataClassName('VisitedArtist')
class ArtistVisits extends Table {
  TextColumn get id => text()(); // browseId del canal (UC…)
  TextColumn get name => text()();
  TextColumn get thumbnailUrl => text().nullable()();
  DateTimeColumn get visitedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Metadatos de las canciones descargadas: alimenta el diálogo de
/// descargas de settings sin leer el disco. `deletedAt` conserva el id
/// tras borrar el archivo para no volver a enriquecer.
@DataClassName('CachedTrackRow')
class CachedTracks extends Table {
  TextColumn get id => text()(); // YouTube video id
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get thumbnailUrl => text().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  DateTimeColumn get downloadedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// Tiempo de escucha real (chunks): alimenta el recap. `playlistId`
// nulleable y sin FK: la playlist puede borrarse después.
@DataClassName('ListenSessionRow')
class ListenSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackId => text().references(Tracks, #id)();
  IntColumn get playlistId => integer().nullable()();
  IntColumn get seconds => integer()();
  DateTimeColumn get listenedAt => dateTime()();
}

// Álbumes (YT Music) guardados con el corazón. Clave: playlistId
// reproducible de YT, con el que se vuelve a leer el tracklist al abrir
// (las URLs de audio expiran). Sin FK: no depende de otras tablas.
@DataClassName('SavedAlbumRow')
class SavedAlbums extends Table {
  TextColumn get id => text()(); // YT Music playlistId del álbum
  TextColumn get title => text()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get year => text().nullable()();
  BoolColumn get isSingle => boolean().withDefault(const Constant(false))();
  DateTimeColumn get savedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

