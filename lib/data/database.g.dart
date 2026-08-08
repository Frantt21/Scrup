// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $TracksTable extends Tracks with TableInfo<$TracksTable, TrackRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
    'artist',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbnailUrlMeta = const VerificationMeta(
    'thumbnailUrl',
  );
  @override
  late final GeneratedColumn<String> thumbnailUrl = GeneratedColumn<String>(
    'thumbnail_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastPlayedMeta = const VerificationMeta(
    'lastPlayed',
  );
  @override
  late final GeneratedColumn<DateTime> lastPlayed = GeneratedColumn<DateTime>(
    'last_played',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _playCountMeta = const VerificationMeta(
    'playCount',
  );
  @override
  late final GeneratedColumn<int> playCount = GeneratedColumn<int>(
    'play_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    artist,
    durationSeconds,
    thumbnailUrl,
    lastPlayed,
    playCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tracks';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrackRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(
        _artistMeta,
        artist.isAcceptableOrUnknown(data['artist']!, _artistMeta),
      );
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    }
    if (data.containsKey('thumbnail_url')) {
      context.handle(
        _thumbnailUrlMeta,
        thumbnailUrl.isAcceptableOrUnknown(
          data['thumbnail_url']!,
          _thumbnailUrlMeta,
        ),
      );
    }
    if (data.containsKey('last_played')) {
      context.handle(
        _lastPlayedMeta,
        lastPlayed.isAcceptableOrUnknown(data['last_played']!, _lastPlayedMeta),
      );
    }
    if (data.containsKey('play_count')) {
      context.handle(
        _playCountMeta,
        playCount.isAcceptableOrUnknown(data['play_count']!, _playCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrackRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      artist: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist'],
      )!,
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      ),
      thumbnailUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_url'],
      ),
      lastPlayed: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_played'],
      ),
      playCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}play_count'],
      )!,
    );
  }

  @override
  $TracksTable createAlias(String alias) {
    return $TracksTable(attachedDatabase, alias);
  }
}

class TrackRow extends DataClass implements Insertable<TrackRow> {
  final String id;
  final String title;
  final String artist;
  final int? durationSeconds;
  final String? thumbnailUrl;
  final DateTime? lastPlayed;
  final int playCount;
  const TrackRow({
    required this.id,
    required this.title,
    required this.artist,
    this.durationSeconds,
    this.thumbnailUrl,
    this.lastPlayed,
    required this.playCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    if (!nullToAbsent || durationSeconds != null) {
      map['duration_seconds'] = Variable<int>(durationSeconds);
    }
    if (!nullToAbsent || thumbnailUrl != null) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl);
    }
    if (!nullToAbsent || lastPlayed != null) {
      map['last_played'] = Variable<DateTime>(lastPlayed);
    }
    map['play_count'] = Variable<int>(playCount);
    return map;
  }

  TracksCompanion toCompanion(bool nullToAbsent) {
    return TracksCompanion(
      id: Value(id),
      title: Value(title),
      artist: Value(artist),
      durationSeconds: durationSeconds == null && nullToAbsent
          ? const Value.absent()
          : Value(durationSeconds),
      thumbnailUrl: thumbnailUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbnailUrl),
      lastPlayed: lastPlayed == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPlayed),
      playCount: Value(playCount),
    );
  }

  factory TrackRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      durationSeconds: serializer.fromJson<int?>(json['durationSeconds']),
      thumbnailUrl: serializer.fromJson<String?>(json['thumbnailUrl']),
      lastPlayed: serializer.fromJson<DateTime?>(json['lastPlayed']),
      playCount: serializer.fromJson<int>(json['playCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'durationSeconds': serializer.toJson<int?>(durationSeconds),
      'thumbnailUrl': serializer.toJson<String?>(thumbnailUrl),
      'lastPlayed': serializer.toJson<DateTime?>(lastPlayed),
      'playCount': serializer.toJson<int>(playCount),
    };
  }

  TrackRow copyWith({
    String? id,
    String? title,
    String? artist,
    Value<int?> durationSeconds = const Value.absent(),
    Value<String?> thumbnailUrl = const Value.absent(),
    Value<DateTime?> lastPlayed = const Value.absent(),
    int? playCount,
  }) => TrackRow(
    id: id ?? this.id,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    durationSeconds: durationSeconds.present
        ? durationSeconds.value
        : this.durationSeconds,
    thumbnailUrl: thumbnailUrl.present ? thumbnailUrl.value : this.thumbnailUrl,
    lastPlayed: lastPlayed.present ? lastPlayed.value : this.lastPlayed,
    playCount: playCount ?? this.playCount,
  );
  TrackRow copyWithCompanion(TracksCompanion data) {
    return TrackRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      thumbnailUrl: data.thumbnailUrl.present
          ? data.thumbnailUrl.value
          : this.thumbnailUrl,
      lastPlayed: data.lastPlayed.present
          ? data.lastPlayed.value
          : this.lastPlayed,
      playCount: data.playCount.present ? data.playCount.value : this.playCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('lastPlayed: $lastPlayed, ')
          ..write('playCount: $playCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    artist,
    durationSeconds,
    thumbnailUrl,
    lastPlayed,
    playCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.durationSeconds == this.durationSeconds &&
          other.thumbnailUrl == this.thumbnailUrl &&
          other.lastPlayed == this.lastPlayed &&
          other.playCount == this.playCount);
}

class TracksCompanion extends UpdateCompanion<TrackRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> artist;
  final Value<int?> durationSeconds;
  final Value<String?> thumbnailUrl;
  final Value<DateTime?> lastPlayed;
  final Value<int> playCount;
  final Value<int> rowid;
  const TracksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.lastPlayed = const Value.absent(),
    this.playCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TracksCompanion.insert({
    required String id,
    required String title,
    this.artist = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.lastPlayed = const Value.absent(),
    this.playCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title);
  static Insertable<TrackRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<int>? durationSeconds,
    Expression<String>? thumbnailUrl,
    Expression<DateTime>? lastPlayed,
    Expression<int>? playCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
      if (lastPlayed != null) 'last_played': lastPlayed,
      if (playCount != null) 'play_count': playCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TracksCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? artist,
    Value<int?>? durationSeconds,
    Value<String?>? thumbnailUrl,
    Value<DateTime?>? lastPlayed,
    Value<int>? playCount,
    Value<int>? rowid,
  }) {
    return TracksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      playCount: playCount ?? this.playCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (thumbnailUrl.present) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl.value);
    }
    if (lastPlayed.present) {
      map['last_played'] = Variable<DateTime>(lastPlayed.value);
    }
    if (playCount.present) {
      map['play_count'] = Variable<int>(playCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TracksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('lastPlayed: $lastPlayed, ')
          ..write('playCount: $playCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HistoryTable extends History with TableInfo<$HistoryTable, HistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _trackIdMeta = const VerificationMeta(
    'trackId',
  );
  @override
  late final GeneratedColumn<String> trackId = GeneratedColumn<String>(
    'track_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tracks (id)',
    ),
  );
  static const VerificationMeta _playedAtMeta = const VerificationMeta(
    'playedAt',
  );
  @override
  late final GeneratedColumn<DateTime> playedAt = GeneratedColumn<DateTime>(
    'played_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, trackId, playedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history';
  @override
  VerificationContext validateIntegrity(
    Insertable<HistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('track_id')) {
      context.handle(
        _trackIdMeta,
        trackId.isAcceptableOrUnknown(data['track_id']!, _trackIdMeta),
      );
    } else if (isInserting) {
      context.missing(_trackIdMeta);
    }
    if (data.containsKey('played_at')) {
      context.handle(
        _playedAtMeta,
        playedAt.isAcceptableOrUnknown(data['played_at']!, _playedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      trackId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}track_id'],
      )!,
      playedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}played_at'],
      )!,
    );
  }

  @override
  $HistoryTable createAlias(String alias) {
    return $HistoryTable(attachedDatabase, alias);
  }
}

class HistoryRow extends DataClass implements Insertable<HistoryRow> {
  final int id;
  final String trackId;
  final DateTime playedAt;
  const HistoryRow({
    required this.id,
    required this.trackId,
    required this.playedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['track_id'] = Variable<String>(trackId);
    map['played_at'] = Variable<DateTime>(playedAt);
    return map;
  }

  HistoryCompanion toCompanion(bool nullToAbsent) {
    return HistoryCompanion(
      id: Value(id),
      trackId: Value(trackId),
      playedAt: Value(playedAt),
    );
  }

  factory HistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryRow(
      id: serializer.fromJson<int>(json['id']),
      trackId: serializer.fromJson<String>(json['trackId']),
      playedAt: serializer.fromJson<DateTime>(json['playedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'trackId': serializer.toJson<String>(trackId),
      'playedAt': serializer.toJson<DateTime>(playedAt),
    };
  }

  HistoryRow copyWith({int? id, String? trackId, DateTime? playedAt}) =>
      HistoryRow(
        id: id ?? this.id,
        trackId: trackId ?? this.trackId,
        playedAt: playedAt ?? this.playedAt,
      );
  HistoryRow copyWithCompanion(HistoryCompanion data) {
    return HistoryRow(
      id: data.id.present ? data.id.value : this.id,
      trackId: data.trackId.present ? data.trackId.value : this.trackId,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryRow(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, trackId, playedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryRow &&
          other.id == this.id &&
          other.trackId == this.trackId &&
          other.playedAt == this.playedAt);
}

class HistoryCompanion extends UpdateCompanion<HistoryRow> {
  final Value<int> id;
  final Value<String> trackId;
  final Value<DateTime> playedAt;
  const HistoryCompanion({
    this.id = const Value.absent(),
    this.trackId = const Value.absent(),
    this.playedAt = const Value.absent(),
  });
  HistoryCompanion.insert({
    this.id = const Value.absent(),
    required String trackId,
    required DateTime playedAt,
  }) : trackId = Value(trackId),
       playedAt = Value(playedAt);
  static Insertable<HistoryRow> custom({
    Expression<int>? id,
    Expression<String>? trackId,
    Expression<DateTime>? playedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (trackId != null) 'track_id': trackId,
      if (playedAt != null) 'played_at': playedAt,
    });
  }

  HistoryCompanion copyWith({
    Value<int>? id,
    Value<String>? trackId,
    Value<DateTime>? playedAt,
  }) {
    return HistoryCompanion(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      playedAt: playedAt ?? this.playedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (trackId.present) {
      map['track_id'] = Variable<String>(trackId.value);
    }
    if (playedAt.present) {
      map['played_at'] = Variable<DateTime>(playedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryCompanion(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $TracksTable tracks = $TracksTable(this);
  late final $HistoryTable history = $HistoryTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [tracks, history];
}

typedef $$TracksTableCreateCompanionBuilder =
    TracksCompanion Function({
      required String id,
      required String title,
      Value<String> artist,
      Value<int?> durationSeconds,
      Value<String?> thumbnailUrl,
      Value<DateTime?> lastPlayed,
      Value<int> playCount,
      Value<int> rowid,
    });
typedef $$TracksTableUpdateCompanionBuilder =
    TracksCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> artist,
      Value<int?> durationSeconds,
      Value<String?> thumbnailUrl,
      Value<DateTime?> lastPlayed,
      Value<int> playCount,
      Value<int> rowid,
    });

final class $$TracksTableReferences
    extends BaseReferences<_$AppDatabase, $TracksTable, TrackRow> {
  $$TracksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$HistoryTable, List<HistoryRow>> _historyRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.history,
    aliasName: 'tracks__id__history__track_id',
  );

  $$HistoryTableProcessedTableManager get historyRefs {
    final manager = $$HistoryTableTableManager(
      $_db,
      $_db.history,
    ).filter((f) => f.trackId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_historyRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TracksTableFilterComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastPlayed => $composableBuilder(
    column: $table.lastPlayed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> historyRefs(
    Expression<bool> Function($$HistoryTableFilterComposer f) f,
  ) {
    final $$HistoryTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.history,
      getReferencedColumn: (t) => t.trackId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HistoryTableFilterComposer(
            $db: $db,
            $table: $db.history,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TracksTableOrderingComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastPlayed => $composableBuilder(
    column: $table.lastPlayed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TracksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastPlayed => $composableBuilder(
    column: $table.lastPlayed,
    builder: (column) => column,
  );

  GeneratedColumn<int> get playCount =>
      $composableBuilder(column: $table.playCount, builder: (column) => column);

  Expression<T> historyRefs<T extends Object>(
    Expression<T> Function($$HistoryTableAnnotationComposer a) f,
  ) {
    final $$HistoryTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.history,
      getReferencedColumn: (t) => t.trackId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HistoryTableAnnotationComposer(
            $db: $db,
            $table: $db.history,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TracksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TracksTable,
          TrackRow,
          $$TracksTableFilterComposer,
          $$TracksTableOrderingComposer,
          $$TracksTableAnnotationComposer,
          $$TracksTableCreateCompanionBuilder,
          $$TracksTableUpdateCompanionBuilder,
          (TrackRow, $$TracksTableReferences),
          TrackRow,
          PrefetchHooks Function({bool historyRefs})
        > {
  $$TracksTableTableManager(_$AppDatabase db, $TracksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TracksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TracksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TracksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> artist = const Value.absent(),
                Value<int?> durationSeconds = const Value.absent(),
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<DateTime?> lastPlayed = const Value.absent(),
                Value<int> playCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TracksCompanion(
                id: id,
                title: title,
                artist: artist,
                durationSeconds: durationSeconds,
                thumbnailUrl: thumbnailUrl,
                lastPlayed: lastPlayed,
                playCount: playCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String> artist = const Value.absent(),
                Value<int?> durationSeconds = const Value.absent(),
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<DateTime?> lastPlayed = const Value.absent(),
                Value<int> playCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TracksCompanion.insert(
                id: id,
                title: title,
                artist: artist,
                durationSeconds: durationSeconds,
                thumbnailUrl: thumbnailUrl,
                lastPlayed: lastPlayed,
                playCount: playCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$TracksTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({historyRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (historyRefs) db.history],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (historyRefs)
                    await $_getPrefetchedData<
                      TrackRow,
                      $TracksTable,
                      HistoryRow
                    >(
                      currentTable: table,
                      referencedTable: $$TracksTableReferences
                          ._historyRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$TracksTableReferences(db, table, p0).historyRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.trackId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$TracksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TracksTable,
      TrackRow,
      $$TracksTableFilterComposer,
      $$TracksTableOrderingComposer,
      $$TracksTableAnnotationComposer,
      $$TracksTableCreateCompanionBuilder,
      $$TracksTableUpdateCompanionBuilder,
      (TrackRow, $$TracksTableReferences),
      TrackRow,
      PrefetchHooks Function({bool historyRefs})
    >;
typedef $$HistoryTableCreateCompanionBuilder =
    HistoryCompanion Function({
      Value<int> id,
      required String trackId,
      required DateTime playedAt,
    });
typedef $$HistoryTableUpdateCompanionBuilder =
    HistoryCompanion Function({
      Value<int> id,
      Value<String> trackId,
      Value<DateTime> playedAt,
    });

final class $$HistoryTableReferences
    extends BaseReferences<_$AppDatabase, $HistoryTable, HistoryRow> {
  $$HistoryTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TracksTable _trackIdTable(_$AppDatabase db) =>
      db.tracks.createAlias('history__track_id__tracks__id');

  $$TracksTableProcessedTableManager get trackId {
    final $_column = $_itemColumn<String>('track_id')!;

    final manager = $$TracksTableTableManager(
      $_db,
      $_db.tracks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_trackIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$HistoryTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryTable> {
  $$HistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$TracksTableFilterComposer get trackId {
    final $$TracksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableFilterComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryTable> {
  $$HistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$TracksTableOrderingComposer get trackId {
    final $$TracksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableOrderingComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryTable> {
  $$HistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);

  $$TracksTableAnnotationComposer get trackId {
    final $$TracksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableAnnotationComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HistoryTable,
          HistoryRow,
          $$HistoryTableFilterComposer,
          $$HistoryTableOrderingComposer,
          $$HistoryTableAnnotationComposer,
          $$HistoryTableCreateCompanionBuilder,
          $$HistoryTableUpdateCompanionBuilder,
          (HistoryRow, $$HistoryTableReferences),
          HistoryRow,
          PrefetchHooks Function({bool trackId})
        > {
  $$HistoryTableTableManager(_$AppDatabase db, $HistoryTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> trackId = const Value.absent(),
                Value<DateTime> playedAt = const Value.absent(),
              }) => HistoryCompanion(
                id: id,
                trackId: trackId,
                playedAt: playedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String trackId,
                required DateTime playedAt,
              }) => HistoryCompanion.insert(
                id: id,
                trackId: trackId,
                playedAt: playedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$HistoryTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({trackId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (trackId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.trackId,
                                referencedTable: $$HistoryTableReferences
                                    ._trackIdTable(db),
                                referencedColumn: $$HistoryTableReferences
                                    ._trackIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$HistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HistoryTable,
      HistoryRow,
      $$HistoryTableFilterComposer,
      $$HistoryTableOrderingComposer,
      $$HistoryTableAnnotationComposer,
      $$HistoryTableCreateCompanionBuilder,
      $$HistoryTableUpdateCompanionBuilder,
      (HistoryRow, $$HistoryTableReferences),
      HistoryRow,
      PrefetchHooks Function({bool trackId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$TracksTableTableManager get tracks =>
      $$TracksTableTableManager(_db, _db.tracks);
  $$HistoryTableTableManager get history =>
      $$HistoryTableTableManager(_db, _db.history);
}
