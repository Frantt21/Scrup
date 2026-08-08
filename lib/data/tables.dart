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
