import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/track.dart';
import 'tables.dart';

part 'database.g.dart';

/// Domain model for a playlist (avoids filtering drift's DataClass).
class Playlist {
  final int id;
  final String name;
  final DateTime createdAt;

  /// Playlist cover (URL of the artwork of one of its songs, or a local path if the user chose one).
  final String? coverUrl;

  /// Optional description written by the user.
  final String? description;

  /// Special Favorites playlist (always last, cannot be deleted).
  final bool isFavorites;

  /// Last time the playlist was played (null if never played).
  final DateTime? lastPlayedAt;

  const Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    this.coverUrl,
    this.description,
    this.isFavorites = false,
    this.lastPlayedAt,
  });
}

@DriftDatabase(
  tables: [Tracks, History, Playlists, PlaylistTracks, Lyrics, PaletteCache],
)
class AppDatabase extends _$AppDatabase {
  /// [executor] lets tests inject an in-memory database.
  AppDatabase({QueryExecutor? executor})
    : super(executor ?? driftDatabase(name: 'scrup'));

  @override
  int get schemaVersion => 9;

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
      if (from < 3) {
        // Álbum enriquecido (Deezer)
        await m.addColumn(tracks, tracks.album);
      }
      if (from < 4) {
        // Portada de la playlist
        await m.addColumn(playlists, playlists.coverUrl);
      }
      if (from < 5) {
        // Descripción de la playlist
        await m.addColumn(playlists, playlists.description);
      }
      if (from < 6) {
        // Playlist especial de Favoritos
        await m.addColumn(playlists, playlists.isFavorites);
      }
      if (from < 7) {
        // Cached lyrics table
        await m.createTable(lyrics);
        // Migrate old lyrics from SharedPreferences to SQLite (once).
        await _migrateSharedPrefsLyrics();
      }
      if (from < 8) {
        // Artwork palette cache (accent + fullscreen trio), formerly in
        // palette_cache.json. The old JSON is removed best-effort on startup
        // (see PaletteCacheStore.load).
        await m.createTable(paletteCache);
      }
      if (from < 9) {
        // Last played timestamp for a playlist (for "recent playlists").
        await m.addColumn(playlists, playlists.lastPlayedAt);
      }
    },
  );

  // -------------------------------------------------- paletas de artwork

  /// Insert or update a palette entry (single accent: [colors] with 1 element; fullscreen trio: 3). Updates `usedAt` for LRU.
  Future<void> upsertPalette(String url, List<int> colors) async {
    assert(colors.isNotEmpty && colors.length <= 3);
    await into(paletteCache).insertOnConflictUpdate(
      // Non-nullable columns with no default: raw value (not Value).
      PaletteCacheCompanion.insert(
        id: url,
        c1: colors[0],
        c2: Value(colors.length > 1 ? colors[1] : null),
        c3: Value(colors.length > 2 ? colors[2] : null),
      ),
    );
  }

  /// All persisted entries (to populate the in-memory cache on startup).
  Future<List<PaletteRow>> allPalettes() => select(paletteCache).get();

  /// LRU trim: keep only the [keep] most recently used entries.
  Future<void> trimPalettes(int keep) async {
    await customStatement(
      'DELETE FROM palette_cache WHERE id NOT IN '
      '(SELECT id FROM palette_cache ORDER BY used_at DESC LIMIT ?)',
      [keep],
    );
  }

  /// Delete a palette entry (manual recalculation).
  Future<void> deletePalette(String url) async {
    await (delete(paletteCache)..where((r) => r.id.equals(url))).go();
  }

  /// Distinct artwork URLs from a playlist (for palette recalculation).
  Future<List<String>> distinctPlaylistArtworks(int playlistId) async {
    final query = selectOnly(
      playlistTracks,
    ).join([innerJoin(tracks, tracks.id.equalsExp(playlistTracks.trackId))]);
    query.addColumns([tracks.thumbnailUrl]);
    query.where(playlistTracks.playlistId.equals(playlistId));
    query.groupBy([tracks.thumbnailUrl]);
    final rows = await query.get();
    return [
      for (final row in rows)
        if (row.read(tracks.thumbnailUrl) case final url? when url.isNotEmpty)
          url,
    ];
  }

  // -------------------------------------------------------------- lyrics
  String _lyricsKey(String title, String artist) =>
      '${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}';

  /// Save lyrics (LRC) to the database.
  Future<void> storeLyrics(
    String title,
    String artist,
    String lrcContent, {
    required bool notFound,
  }) async {
    final key = _lyricsKey(title, artist);
    await into(lyrics).insertOnConflictUpdate(
      LyricsCompanion(
        id: Value(key),
        lrcContent: Value(lrcContent),
        isNotFound: Value(notFound),
        fetchedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Get stored lyrics, or null if none exist.
  Future<String?> getStoredLrc(String title, String artist) async {
    final key = _lyricsKey(title, artist);
    final row = await (select(
      lyrics,
    )..where((l) => l.id.equals(key))).getSingleOrNull();
    if (row == null) return null;
    if (row.isNotFound) return null;
    return row.lrcContent.isEmpty ? null : row.lrcContent;
  }

  /// Mark a song as "lyrics not found" to avoid repeated searches.
  Future<void> markLyricsNotFound(String title, String artist) async {
    final key = _lyricsKey(title, artist);
    await into(lyrics).insertOnConflictUpdate(
      LyricsCompanion(
        id: Value(key),
        lrcContent: const Value(''),
        isNotFound: const Value(true),
        fetchedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Delete cached lyrics for a song.
  Future<void> deleteLyrics(String title, String artist) async {
    final key = _lyricsKey(title, artist);
    await (delete(lyrics)..where((l) => l.id.equals(key))).go();
  }

  /// Migrate lyrics from SharedPreferences (legacy format) to SQLite.
  /// It runs once during the v6->v7 migration and clears the old SharedPreferences keys afterward.
  Future<void> _migrateSharedPrefsLyrics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final prefKey in keys) {
        if (prefKey.startsWith('scrup_lyrics_nf_')) {
          // Mark "not found" -> migrate as isNotFound=true
          final songKey = prefKey.replaceFirst('scrup_lyrics_nf_', '');
          await into(lyrics).insertOnConflictUpdate(
            LyricsCompanion(
              id: Value(songKey),
              lrcContent: const Value(''),
              isNotFound: const Value(true),
              fetchedAt: Value(DateTime.now()),
            ),
          );
          await prefs.remove(prefKey);
          continue;
        }
        if (!prefKey.startsWith('scrup_lyrics_')) continue;
        // Found lyrics -> migrate as isNotFound=false
        final lrcContent = prefs.getString(prefKey);
        final songKey = prefKey.replaceFirst('scrup_lyrics_', '');
        if (lrcContent == null || lrcContent.isEmpty) {
          await prefs.remove(prefKey);
          continue;
        }
        await into(lyrics).insertOnConflictUpdate(
          LyricsCompanion(
            id: Value(songKey),
            lrcContent: Value(lrcContent),
            isNotFound: const Value(false),
            fetchedAt: Value(DateTime.now()),
          ),
        );
        await prefs.remove(prefKey);
      }
    } catch (_) {
      // Silent: the migration is best-effort.
    }
  }

  // ---------------------------------------------------------------- cache
  /// Save (or update) a track's metadata. We never save the audio URL because it expires.
  Future<void> cacheTrack(Track track) async {
    await into(tracks).insertOnConflictUpdate(
      TracksCompanion.insert(
        id: track.id,
        title: track.title,
        artist: Value(track.artist),
        durationSeconds: Value(track.duration?.inSeconds),
        thumbnailUrl: Value(track.thumbnailUrl),
        album: Value(track.album),
      ),
    );
  }

  /// Update a cached track's metadata (e.g. when Deezer enrichment arrives) without touching history. Since recent tracks JOIN `tracks`, the enriched artwork/album appear instantly on the home screen.
  Future<void> updateTrackMetadata(Track track) => cacheTrack(track);

  /// Return a track's cached metadata, if any exist.
  Future<Track?> getCachedTrack(String id) async {
    final row = await (select(
      tracks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _trackFromRow(row);
  }

  /// Recent songs played (for the offline home screen).
  ///
  /// Deduplicate by track id: each song appears only once, using the most recent play. History is bounded by pruning (60 days), so we fetch all rows and deduplicate in memory.
  Stream<List<Track>> watchRecentlyPlayed({int limit = 30}) {
    final query =
        (select(history)..orderBy([(h) => OrderingTerm.desc(h.playedAt)])).join(
          [innerJoin(tracks, tracks.id.equalsExp(history.trackId))],
        );

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
  /// Record a play (mark lastPlayed, increment playCount, add a history row).
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
    // Pruning: keep only the last 60 days of history
    await (delete(history)..where(
          (h) => h.playedAt.isSmallerThanValue(
            DateTime.now().subtract(const Duration(days: 60)),
          ),
        ))
        .go();
  }

  // ------------------------------------------------------------ playlists
  Stream<List<Playlist>> watchPlaylists() {
    // Favorites always last (isFavorites=false first); the rest by
    // creation, most recent first.
    final query = select(playlists)
      ..orderBy([
        (p) => OrderingTerm.asc(p.isFavorites),
        (p) => OrderingTerm.desc(p.createdAt),
      ]);
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => Playlist(
              id: r.id,
              name: r.name,
              createdAt: r.createdAt,
              coverUrl: r.coverUrl,
              description: r.description,
              isFavorites: r.isFavorites,
              lastPlayedAt: r.lastPlayedAt,
            ),
          )
          .toList(),
    );
  }

  /// Watch playlists by play date (most recent first), for the home recent playlists section. Only playlists that have been played at least once.
  Stream<List<Playlist>> watchRecentPlaylists({int limit = 10}) {
    final query = select(playlists)
      ..where((p) => p.lastPlayedAt.isNotNull())
      ..orderBy([(p) => OrderingTerm.desc(p.lastPlayedAt)])
      ..limit(limit);
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => Playlist(
              id: r.id,
              name: r.name,
              createdAt: r.createdAt,
              coverUrl: r.coverUrl,
              description: r.description,
              isFavorites: r.isFavorites,
              lastPlayedAt: r.lastPlayedAt,
            ),
          )
          .toList(),
    );
  }

  /// Record that [playlistId] was played now (for recent playlists).
  Future<void> markPlaylistPlayed(int playlistId) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(lastPlayedAt: Value(DateTime.now())),
    );
  }

  /// Watch a specific playlist (to reflect cover changes in the detail view).
  Stream<Playlist?> watchPlaylist(int id) {
    final query = select(playlists)..where((p) => p.id.equals(id));
    return query.watchSingleOrNull().map(
      (r) => r == null
          ? null
          : Playlist(
              id: r.id,
              name: r.name,
              createdAt: r.createdAt,
              coverUrl: r.coverUrl,
              description: r.description,
              isFavorites: r.isFavorites,
              lastPlayedAt: r.lastPlayedAt,
            ),
    );
  }

  /// Number of songs per playlist (to show on the grid cards).
  Stream<Map<int, int>> watchPlaylistTrackCounts() {
    final query = selectOnly(playlistTracks)
      ..addColumns([playlistTracks.playlistId, playlistTracks.trackId.count()])
      ..groupBy([playlistTracks.playlistId]);
    return query.watch().map((rows) {
      final counts = <int, int>{};
      for (final row in rows) {
        final id = row.read(playlistTracks.playlistId);
        final count = row.read(playlistTracks.trackId.count()) ?? 0;
        if (id != null) counts[id] = count;
      }
      return counts;
    });
  }

  /// Create a playlist and return its id.
  Future<int> createPlaylist(String name) async {
    final id = await into(
      playlists,
    ).insert(PlaylistsCompanion.insert(name: name));
    return id;
  }

  Future<void> deletePlaylist(int id) async {
    await (delete(
      playlistTracks,
    )..where((pt) => pt.playlistId.equals(id))).go();
    await (delete(playlists)..where((p) => p.id.equals(id))).go();
  }

  Future<Playlist?> getPlaylist(int id) async {
    final row = await (select(
      playlists,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return Playlist(
      id: row.id,
      name: row.name,
      createdAt: row.createdAt,
      coverUrl: row.coverUrl,
      description: row.description,
      isFavorites: row.isFavorites,
    );
  }

  /// Establece la portada de una playlist (o la quita con `null`).
  Future<void> setPlaylistCover(int playlistId, String? coverUrl) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(coverUrl: Value(coverUrl)),
    );
  }

  /// Establece la descripción de una playlist (o la quita con `null`).
  Future<void> setPlaylistDescription(
    int playlistId,
    String? description,
  ) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(description: Value(description)),
    );
  }

  /// Cambia el nombre de una playlist.
  Future<void> renamePlaylist(int playlistId, String name) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(name: Value(name)),
    );
  }

  /// Return the Favorites playlist id, creating it if it does not exist.
  Future<int> ensureFavoritesPlaylist() async {
    final existing = await (select(
      playlists,
    )..where((p) => p.isFavorites.equals(true))).getSingleOrNull();
    if (existing != null) return existing.id;
    return into(playlists).insert(
      PlaylistsCompanion.insert(
        name: 'Favoritos',
        isFavorites: const Value(true),
      ),
    );
  }

  /// ids of playlists that already contain [trackId]: the "add to playlist" modal marks those with a check.
  Future<Set<int>> playlistIdsContainingTrack(String trackId) async {
    final rows = await (select(
      playlistTracks,
    )..where((pt) => pt.trackId.equals(trackId))).get();
    return rows.map((r) => r.playlistId).toSet();
  }

  /// `true` while the track is in the playlist (reactive stream).
  Stream<bool> watchTrackInPlaylist(int playlistId, String trackId) {
    final query = select(playlistTracks)
      ..where(
        (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId),
      );
    return query.watch().map((rows) => rows.isNotEmpty);
  }

  /// Songs of a playlist (with cached metadata), in order.
  Stream<List<Track>> watchPlaylistTracks(int playlistId) {
    final query =
        (select(playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId))
              ..orderBy([(pt) => OrderingTerm.asc(pt.position)]))
            .join([
              innerJoin(tracks, tracks.id.equalsExp(playlistTracks.trackId)),
            ]);

    return query.watch().map((rows) {
      return rows.map((row) => _trackFromRow(row.readTable(tracks))).toList();
    });
  }

  /// Add a song to the end of a playlist (no duplicates).
  Future<void> addToPlaylist(int playlistId, Track track) async {
    await cacheTrack(track);
    final existing =
        await (select(playlistTracks)..where(
              (pt) =>
                  pt.playlistId.equals(playlistId) &
                  pt.trackId.equals(track.id),
            ))
            .get();
    if (existing.isNotEmpty) return;

    final maxPos =
        await (selectOnly(playlistTracks)
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

    // Default cover: if the playlist still has none and the song has artwork, use it as the cover.
    final playlist = await getPlaylist(playlistId);
    if (playlist != null &&
        playlist.coverUrl == null &&
        track.thumbnailUrl != null) {
      await setPlaylistCover(playlistId, track.thumbnailUrl);
    }
  }

  Future<void> removeFromPlaylist(int playlistId, String trackId) async {
    await (delete(playlistTracks)..where(
          (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId),
        ))
        .go();
  }

  /// Most recently added tracks to [playlistId] (for the home "Your likes" banner: the 3 most recent covers, overlaid). It uses the playlist order (position DESC) as a proxy for "most recently added".
  Stream<List<Track>> watchLatestPlaylistTracks(
    int playlistId, {
    int limit = 3,
  }) {
    final query =
        (select(playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId))
              ..orderBy([
                (pt) => OrderingTerm.desc(pt.position),
              ])
              ..limit(limit))
            .join([
              innerJoin(tracks, tracks.id.equalsExp(playlistTracks.trackId)),
            ]);

    return query.watch().map((rows) {
      return rows.map((row) => _trackFromRow(row.readTable(tracks))).toList();
    });
  }

  /// Reorder the songs of [playlistId] according to [trackIds] (full final order): a batch of position UPDATEs in one transaction. The `watchPlaylistTracks` stream re-emits the persisted order.
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<String> trackIds,
  ) async {
    await batch((b) {
      for (var i = 0; i < trackIds.length; i++) {
        b.update(
          playlistTracks,
          PlaylistTracksCompanion(position: Value(i + 1)),
          where: (pt) =>
              pt.playlistId.equals(playlistId) & pt.trackId.equals(trackIds[i]),
        );
      }
    });
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
      album: row.album,
    );
  }
}
