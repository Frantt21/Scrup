import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/track.dart';
import '../services/ytmusic_service.dart' show YtmAlbum;
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

/// Recap "playlists más escuchadas": total de segundos por playlist.
/// `playlistId` null = escuchas sin playlist; `name` vacío = playlist borrada.
class RecapPlaylistEntry {
  final int? playlistId;
  final String name;
  final String? coverUrl;
  final int seconds;

  const RecapPlaylistEntry({
    required this.playlistId,
    required this.name,
    required this.coverUrl,
    required this.seconds,
  });
}

/// Nombre lógico de la BD: drift crea `<name>.sqlite` dentro de
/// [resolveDatabaseDirectory].
const String _databaseName = 'scrup';

/// Directorio donde vive la BD. En escritorio usa
/// `getApplicationSupportDirectory()` (siempre escribible, incluso en Flatpak),
/// en móvil `getApplicationDocumentsDirectory()` (ya es privado y escribible).
/// La BD antigua de Documents se copia aquí la primera vez (no se borra).
/// Los parámetros inyectables existen solo para los tests.
Future<Directory> resolveDatabaseDirectory({
  Future<Directory> Function()? supportDir,
  Future<Directory> Function()? documentsDir,
  bool Function()? isMobile,
}) async {
  final mobile = (isMobile ?? _defaultIsMobile)();
  if (mobile) return await (documentsDir ?? getApplicationDocumentsDirectory)();
  final support = await (supportDir ?? getApplicationSupportDirectory)();
  final fallback = await _migrateLegacyDatabase(
    support,
    documentsDir: documentsDir ?? getApplicationDocumentsDirectory,
  );    // Si la BD escritorio migró, úsala para no perder el historial local.
    return fallback ?? support;
}

bool _defaultIsMobile() => Platform.isAndroid || Platform.isIOS;

/// Copia la BD antigua de `Documents` a [target] si aún no existe. Devuelve
/// el directorio ANTIGUO si hay BD y la copia falló (mejor abrir la antigua,
/// aunque sea de solo lectura, que arrancar vacía). `null` si no había nada.
Future<Directory?> _migrateLegacyDatabase(
  Directory target, {
  required Future<Directory> Function() documentsDir,
}) async {
  final targetFile = File(p.join(target.path, '$_databaseName.sqlite'));
  if (targetFile.existsSync()) return null;
  Directory? legacyDir;
  try {
    legacyDir = await documentsDir();
    final legacyFile = File(p.join(legacyDir.path, '$_databaseName.sqlite'));
    if (!legacyFile.existsSync()) return null;
    await target.create(recursive: true);
    // Los adjuntos WAL/SHM van con la BD: sin ellos se perderían las
    // transacciones aún no fusionadas al fichero principal.
    for (final suffix in const ['', '-wal', '-shm']) {
      final source = File('${legacyFile.path}$suffix');
      if (source.existsSync()) await source.copy('${targetFile.path}$suffix');
    }
    debugPrint('[scrup/db] BD migrada de $legacyDir a $target');
    return null;
  } catch (e) {
    debugPrint('[scrup/db] migración Documents fallida: $e');
    try {
      if (legacyDir != null &&
          File(p.join(legacyDir.path, '$_databaseName.sqlite')).existsSync()) {
        return legacyDir;
      }
    } catch (_) {}
    return null;
  }
}

@DriftDatabase(
      tables: [
        Tracks,
        History,
        Playlists,
        PlaylistTracks,
        Lyrics,
        PaletteCache,
        ArtistVisits,
        CachedTracks,
        ListenSessions,
        SavedAlbums,
      ],
)
class AppDatabase extends _$AppDatabase {
  /// [executor] lets tests inject an in-memory database.
  AppDatabase({QueryExecutor? executor}): super(
    executor ?? driftDatabase(
      name: _databaseName,
      native: DriftNativeOptions(
        databaseDirectory: resolveDatabaseDirectory,
      ),
    ),
  );


  @override
  int get schemaVersion => 14;

  /// Registra un fallo de reparación (best-effort) sin reventar el arranque.
  void _logMigrationFailure(String step, Object error) {
    assert(() {
      // ignore: avoid_print
      print('[scrup/db] reparación "$step" falló: $error');
      return true;
    }());
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(playlists);
        await m.createTable(playlistTracks);
      }
      if (from < 3) {
        // Álbum enriquecido (Deezer).
        await m.addColumn(tracks, tracks.album);
      }
      if (from < 4) {
        // Portada de la playlist.
        await m.addColumn(playlists, playlists.coverUrl);
      }
      if (from < 5) {
        // Descripción de la playlist.
        await m.addColumn(playlists, playlists.description);
      }
      if (from < 6) {
        // Playlist especial de Favoritos.
        await m.addColumn(playlists, playlists.isFavorites);
      }
      if (from < 7) {
        // Letra en caché.
        await m.createTable(lyrics);
        await _migrateSharedPrefsLyrics();
      }
      if (from < 8) {
        // Paleta de artwork (acento + trio fullscreen): antes en JSON.
        await m.createTable(paletteCache);
      }
      if (from < 9) {
        // Última reproducción de la playlist (home "recientes").
        await m.addColumn(playlists, playlists.lastPlayedAt);
      }
      if (from < 10) {
        // Artistas visitados (fila home).
        await m.createTable(artistVisits);
      }
      if (from < 11) {
        // Metadatos de descargas (settings dialog).
        await m.createTable(cachedTracks);
      }
      if (from < 12) {
        // Tiempo de escucha (recap).
        await m.createTable(listenSessions);
      }
      if (from < 13) {
        // Canal del artista por pista (avatares del recap).
        // Idempotente: builds anteriores creaban la columna sin subir la
        // versión → un ALTER TABLE plano explotaba con "duplicate column
        // name" y la BD no abría. Cualquier query aquí re-entra en la
        // apertura y re-ejecuta la migración, así que se ignora el error.
        try {
          await m.addColumn(tracks, tracks.artistChannelId);
        } on Exception catch (e) {
          if (!e.toString().contains('duplicate column name')) rethrow;
        }
      }
      if (from < 14) {
        // Álbumes guardados (corazón en la página del álbum): clave
        // playlistId de YT Music para re-resolver el tracklist al abrir.
        await m.createTable(savedAlbums);
      }
    },
    beforeOpen: (details) async {
      // REPARACIÓN best-effort: un fallo nunca debe colgar el arranque.
      try {
        await _ensureFavoritesPlaylist();
      } catch (e) {
        _logMigrationFailure('ensureFavoritesPlaylist', e);
      }
      try {
        await mergeDuplicateFavorites();
      } catch (e) {
        _logMigrationFailure('mergeDuplicateFavorites', e);
      }
      try {
        await rescueOrphanedPlaylistTracks();
      } catch (e) {
        _logMigrationFailure('rescueOrphanedPlaylistTracks', e);
      }
      try {
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_playlists_single_favorites ON playlists (is_favorites) '
          'WHERE is_favorites = 1',
        );
      } catch (e) {
        _logMigrationFailure('idx_playlists_single_favorites', e);
      }
    },
  );

  // ── paletas de artwork ──────────────────────────────────────────────

  /// Upsert de una paleta (1 color = acento; 3 = trio fullscreen).
  /// Actualiza `usedAt` para el recorte LRU.
  Future<void> upsertPalette(String url, List<int> colors) async {
    assert(colors.isNotEmpty && colors.length <= 3);
    await into(paletteCache).insertOnConflictUpdate(
      PaletteCacheCompanion.insert(
        id: url,
        c1: colors[0],
        c2: Value(colors.length > 1 ? colors[1] : null),
        c3: Value(colors.length > 2 ? colors[2] : null),
      ),
    );
  }

  /// Todas las entradas persisted (para poblar la caché en memoria al arrancar).
  Future<List<PaletteRow>> allPalettes() => select(paletteCache).get();

  /// Recorte LRU: se queda con las [keep] entradas más recientes.
  Future<void> trimPalettes(int keep) async {
    await customStatement(
      'DELETE FROM palette_cache WHERE id NOT IN '
      '(SELECT id FROM palette_cache ORDER BY used_at DESC LIMIT ?)',
      [keep],
    );
  }

  /// Elimina una paleta (recalculo manual).
  Future<void> deletePalette(String url) async {
    await (delete(paletteCache)..where((r) => r.id.equals(url))).go();
  }

  /// URLs de artwork distintas de una playlist (para recalcular paletas).
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

  // ── letra ──────────────────────────────────────────────────────────
  String _lyricsKey(String title, String artist) =>
      '${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}';

  /// Persiste letra (LRC).
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

  /// Letra persistida, o null si no existe.
  Future<String?> getStoredLrc(String title, String artist) async {
    final key = _lyricsKey(title, artist);
    final row = await (select(
      lyrics,
    )..where((l) => l.id.equals(key))).getSingleOrNull();
    if (row == null) return null;
    if (row.isNotFound) return null;
    return row.lrcContent.isEmpty ? null : row.lrcContent;
  }

  /// Marca "letra no encontrada" para no repetir búsquedas.
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

  /// Elimina la letra en caché de una canción.
  Future<void> deleteLyrics(String title, String artist) async {
    final key = _lyricsKey(title, artist);
    await (delete(lyrics)..where((l) => l.id.equals(key))).go();
  }

  /// Migra letras de SharedPreferences (formato legacy) a SQLite, una sola
  /// vez en la migración v6→v7, y borra las claves antiguas.
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
    } catch (_) {}
  }

  // ── caché de pistas ──────────────────────────────────────────────────
  /// Persiste (o actualiza) metadatos de una pista. Nunca la URL de audio
  /// porque expira.
  Future<void> cacheTrack(Track track) async {
    await into(tracks).insertOnConflictUpdate(
      TracksCompanion.insert(
        id: track.id,
        title: track.title,
        artist: Value(track.artist),
        durationSeconds: Value(track.duration?.inSeconds),
        thumbnailUrl: Value(track.thumbnailUrl),
        album: Value(track.album),
        artistChannelId: track.artistChannelId == null
            ? const Value.absent()
            : Value(track.artistChannelId),
      ),
    );
  }

  /// Actualiza metadatos sin tocar el historial (el enrich de Deezer, p. ej.).
  /// Las pistas recientes hacen JOIN con `tracks`, así que la portada/álbum
  /// enriquecidos aparecen al momento en home.
  Future<void> updateTrackMetadata(Track track) => cacheTrack(track);

  // ── descargas (audio cache) ─────────────────────────────────────────
  /// Snapshot de una descarga completada. Nunca borra la fila: `deletedAt`
  /// conserva el id para que una re-descarga del mismo video no vuelva a
  /// enriquecer.
  Future<void> upsertCachedTrack({
    required String id,
    String? title,
    String? artist,
    String? thumbnailUrl,
    required int sizeBytes,
  }) async {
    await into(cachedTracks).insertOnConflictUpdate(
      CachedTracksCompanion.insert(
        id: id,
        title: Value(title ?? ''),
        artist: Value(artist ?? ''),
        thumbnailUrl: Value(thumbnailUrl),
        sizeBytes: Value(sizeBytes),
        downloadedAt: Value(DateTime.now()),
        deletedAt: const Value(null),
      ),
    );
  }

  /// Marca la entrada como eliminada del disco (la fila se queda para
  /// re-descargas futuras). No-op si el id es desconocido.
  Future<void> markCachedTrackDeleted(String id) async {
    await (update(
      cachedTracks,
    )..where((ct) => ct.id.equals(id))).write(
      CachedTracksCompanion(deletedAt: Value(DateTime.now())),
    );
  }

  /// Todas las entradas de descargas con metadatos (incluidas las borradas,
  /// marcadas por `deletedAt`), más recientes primero.
  Future<List<CachedTrackRow>> allCachedTracks() {
    final query = select(cachedTracks)
      ..orderBy([(ct) => OrderingTerm.desc(ct.downloadedAt)]);
    return query.get();
  }

  /// Metadatos en caché de una pista, si existen.
  Future<Track?> getCachedTrack(String id) async {
    final row = await (select(
      tracks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _trackFromRow(row);
  }

  /// Canciones reproducidas recientemente (home offline). Deduplicadas por
  /// id: cada canción aparece una vez, con la reproducción más reciente. El
  /// historial se limita a 60 días, así que leemos todo y deduplicamos en
  /// memoria.
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

  // ── historial ──────────────────────────────────────────────────────
  /// Registra una reproducción (lastPlayed, playCount + fila en historial).
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
    // Recorte: solo los últimos 60 días.
    await (delete(history)..where(
          (h) => h.playedAt.isSmallerThanValue(
            DateTime.now().subtract(const Duration(days: 60)),
          ),
        ))
        .go();
  }

  // ── playlists ────────────────────────────────────────────────────────
  /// Playlists ordenadas: favoritos siempre al final, el resto por fecha de
  /// creación (más reciente primero).
  Stream<List<Playlist>> watchPlaylists() {
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

  /// Playlists por fecha de reproducción (más reciente primero), para el
  /// aside de home "playlists recientes". Solo playlists reproducidas al
  /// menos una vez.
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

  /// Marca [playlistId] como reproducido ahora (playlists recientes).
  Future<void> markPlaylistPlayed(int playlistId) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(lastPlayedAt: Value(DateTime.now())),
    );
  }

  /// Una playlist concreta (para reflejar cambios de portada en el detail).
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

  /// Número de canciones por playlist (para las cards del grid).
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

  /// Crea una playlist y devuelve su id.
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

  /// Establece (o quita con `null`) la portada de una playlist.
  Future<void> setPlaylistCover(int playlistId, String? coverUrl) async {
    await (update(playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(coverUrl: Value(coverUrl)),
    );
  }

  /// Establece (o quita con `null`) la descripción de una playlist.
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

  /// Promesa en vuelo del ensure: todos los callers simultáneos comparten
  /// el MISMO futuro. El check-then-insert no es atómico y tres callers en
  /// paralelo (HomeView, PlayerBar, overlay) creaban tres favoritos.
  Future<int>? _favoritesEnsure;

  /// Id de la playlist Favoritos, creándola si no existe.
  Future<int> ensureFavoritesPlaylist() {
    return _favoritesEnsure ??= _ensureFavoritesPlaylist().whenComplete(() {
      _favoritesEnsure = null;
    });
  }

  Future<int> _ensureFavoritesPlaylist() async {
    final existing = await (select(playlists)
          ..where((p) => p.isFavorites.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.id)])
          ..limit(1))
        .get();
    if (existing.isNotEmpty) return existing.first.id;
    // Backstop: el índice único parcial (beforeOpen) rechaza un segundo
    // favorito si algo se saltara la serialización.
    return into(playlists).insert(
      PlaylistsCompanion.insert(
        name: 'Favoritos',
        isFavorites: const Value(true),
      ),
    );
  }

  /// Fusiona las playlists de favoritos duplicadas (carreras de arranque
  /// previas): mueve los tracks a la más antigua (respetando clave única
  /// playlist/track), repunta la portada si faltaba y borra el resto. Sin
  /// esto, el banner "Your likes" podía apuntar a un favorito vacío.
  Future<void> mergeDuplicateFavorites() async {
    final favs = await (select(playlists)
          ..where((p) => p.isFavorites.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.id)]))
        .get();
    if (favs.length < 2) return;
    final keep = favs.first;
    await transaction(() async {
      var nextPos = await (selectOnly(playlistTracks)
            ..addColumns([playlistTracks.position.max()])
            ..where(playlistTracks.playlistId.equals(keep.id)))
          .map((row) => row.read(playlistTracks.position.max()) ?? 0)
          .getSingle();
      for (final dup in favs.skip(1)) {
        final rows = await (select(playlistTracks)
              ..where((pt) => pt.playlistId.equals(dup.id)))
            .get();
        for (final row in rows) {
          final already = await (select(playlistTracks)
                ..where(
                  (pt) =>
                      pt.playlistId.equals(keep.id) &
                      pt.trackId.equals(row.trackId),
                ))
              .get();
          if (already.isEmpty) {
            await into(playlistTracks).insert(
              PlaylistTracksCompanion.insert(
                playlistId: keep.id,
                trackId: row.trackId,
                position: nextPos + 1,
              ),
            );
            nextPos++;
          }
        }
        if (keep.coverUrl == null && dup.coverUrl != null) {
          await (update(playlists)..where((p) => p.id.equals(keep.id))).write(
            PlaylistsCompanion(coverUrl: Value(dup.coverUrl)),
          );
        }
        // Los playlistTracks del duplicado ya se movieron; las filas
        // restantes (repetidas) se borran antes de la playlist por el FK.
        await (delete(playlistTracks)
              ..where((pt) => pt.playlistId.equals(dup.id)))
            .go();
        await (delete(playlists)..where((p) => p.id.equals(dup.id))).go();
      }
    });
  }

  /// Rescata los likes huérfanos: playlistTracks apuntando a playlists
  /// inexistentes. Los mueve al favorito (keep) con posición alta para que
  /// el banner "Your likes" los lea primero. Sin FK activa, el cleanup
  /// buggy anterior dejaba estos huérfanos al borrar la favorito.
  Future<void> rescueOrphanedPlaylistTracks() async {
    final favs = await (select(playlists)
          ..where((p) => p.isFavorites.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.id)])
          ..limit(1))
        .get();
    if (favs.isEmpty) return;
    final keepId = favs.first.id;

    // Left outer join tipado: huérfanos = playlist_tracks sin playlist padre.
    final orphanRows = await (select(playlistTracks).join([
      leftOuterJoin(
        playlists,
        playlists.id.equalsExp(playlistTracks.playlistId),
        useColumns: false,
      ),
    ])..where(playlists.id.isNull()))
        .get();
    if (orphanRows.isEmpty) return;

    var nextPos = await (selectOnly(playlistTracks)
          ..addColumns([playlistTracks.position.max()])
          ..where(playlistTracks.playlistId.equals(keepId)))
        .map((row) => row.read(playlistTracks.position.max()) ?? 0)
        .getSingle();

    await transaction(() async {
      for (final row in orphanRows) {
        final orphan = row.readTable(playlistTracks);
        // La playlist de origen ya no existe: su posición ya no importa.
        // OnConflictUpdate respeta la clave única (playlist, track).
        await into(playlistTracks).insertOnConflictUpdate(
          PlaylistTracksCompanion.insert(
            playlistId: keepId,
            trackId: orphan.trackId,
            position: nextPos + 1,
          ),
        );
        nextPos++;
        await (delete(playlistTracks)
              ..where((pt) => pt.id.equals(orphan.id)))
            .go();
      }
    });
  }

  /// Playlists que ya contienen [trackId] (para marcar con check en el modal).
  Future<Set<int>> playlistIdsContainingTrack(String trackId) async {
    final rows = await (select(
      playlistTracks,
    )..where((pt) => pt.trackId.equals(trackId))).get();
    return rows.map((r) => r.playlistId).toSet();
  }

  /// Track ids de una playlist (lista plana, para agrupar el diálogo de descargas).
  Future<List<String>> playlistTrackIds(int playlistId) async {
    final rows = await (select(
      playlistTracks,
    )..where((pt) => pt.playlistId.equals(playlistId))).get();
    return rows.map((r) => r.trackId).toList();
  }

  /// Tracks by id in ONE query (backfill of the downloads metadata table).
  Future<Map<String, TrackRow>> tracksByIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows = await (select(
      tracks,
    )..where((t) => t.id.isIn(ids))).get();
    return {for (final r in rows) r.id: r};
  }

  /// `true` mientras la pista está en la playlist (stream reactivo).
  Stream<bool> watchTrackInPlaylist(int playlistId, String trackId) {
    final query = select(playlistTracks)
      ..where(
        (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId),
      );
    return query.watch().map((rows) => rows.isNotEmpty);
  }

  /// Canciones de una playlist (con metadatos cacheados), en orden.
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

    // Cover por defecto: si la playlist no tiene portada y la pista tiene
    // artwork, se usa como portada.
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

  /// Pares (álbum, artista) distintos de las pistas guardadas del usuario —
  /// todas las playlists (favoritos incluido), una sola query. Orden: primero
  /// RECENCIA (pista más reciente añadida a una playlist, por su posición)
  /// y luego cuántas canciones distintas comparten el álbum. Así, al añadir
  /// una sola canción, su álbum aparece arriba en vez de quedarse bajo
  /// álbumes con más canciones guardadas. Álbumes nulos se excluyen.
  Future<List<(String, String)>> libraryAlbumSeeds({int limit = 12}) async {
    final countExp = tracks.id.count();
    final recencyExp = playlistTracks.position.max();
    final query = selectOnly(tracks).join([
      innerJoin(playlistTracks, playlistTracks.trackId.equalsExp(tracks.id)),
    ])
      ..addColumns([tracks.album, tracks.artist, countExp, recencyExp])
      ..where(tracks.album.isNull().not() & tracks.album.equals('').not())
      ..groupBy([tracks.album, tracks.artist])
      ..orderBy([
        OrderingTerm.desc(recencyExp),
        OrderingTerm.desc(countExp),
        OrderingTerm.desc(tracks.album),
      ])
      ..limit(limit);
    final rows = await query.get();
    return [
      for (final row in rows)
        (
          row.read(tracks.album)!,
          row.read(tracks.artist) ?? '',
        ),
    ];
  }

  /// Últimas pistas añadidas a [playlistId] (banner home "Your likes":
  /// las 3 portadas más recientes sobrepuestas). Usa el orden de la playlist
  /// (position DESC) como proxy de "añadida más recientemente".
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

  /// Reordena las canciones de [playlistId] según [trackIds] (orden final
  /// completo): un batch de UPDATEs de posición en una sola transacción. El
  /// stream `watchPlaylistTracks` re-emite el orden persisted.
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

  // ── artistas visitados ──────────────────────────────────────────────

  /// Registra/actualiza la visita a un canal (el más reciente primero en
  /// `watchVisitedArtists`). Best-effort: sin artista no pasa nada.
  Future<void> recordArtistVisit({
    required String id,
    required String name,
    String? thumbnailUrl,
  }) async {
    try {
      await into(
        artistVisits,
      ).insertOnConflictUpdate(
        ArtistVisitsCompanion.insert(
          id: id,
          name: name,
          thumbnailUrl: Value(thumbnailUrl),
          visitedAt: DateTime.now(),
        ),
      );
    } catch (_) {}
  }

  /// Artistas visitados, el más reciente primero (home).
  Stream<List<VisitedArtist>> watchVisitedArtists({int limit = 12}) {
    return (select(artistVisits)
          ..orderBy([(a) => OrderingTerm.desc(a.visitedAt)])
          ..limit(limit))
        .watch();
  }

  // ── recap ──────────────────────────────────────────────────────────

  /// Persiste un chunk de escucha (segundos acumulados de la pista actual).
  /// Best-effort desde el tracker del player; una pista faltante (caché
  /// borrada) se ignora por el FK con cascade-off.
  Future<void> recordListenChunk(
    String trackId,
    int seconds, {
    int? playlistId,
  }) async {
    if (seconds <= 0) return;
    // Ensure the track exists (chunks may arrive for tracks not yet cached).
    final exists = await (select(tracks)
          ..where((t) => t.id.equals(trackId)))
        .getSingleOrNull();
    if (exists == null) return;
    await into(listenSessions).insert(
      ListenSessionsCompanion.insert(
        trackId: trackId,
        seconds: seconds,
        playlistId: Value(playlistId),
        listenedAt: DateTime.now(),
      ),
    );
  }

  /// Total de segundos de escucha desde [since] (null = todo el tiempo).
  Future<int> totalListenSeconds({DateTime? since}) async {
    final total = listenSessions.seconds.sum();
    final query = selectOnly(listenSessions)
      ..addColumns([total])
      ..where(
        since == null
            ? const Constant(true)
            : listenSessions.listenedAt.isBiggerThanValue(since),
      );
    final row = await query.getSingle();
    return row.read(total) ?? 0;
  }

  /// Segundos de escucha agrupados por pista, top [limit] primero. Solo
  /// filas cuya pista aún existe (inner join).
  Future<List<(Track, int)>> topListenedTracks({
    DateTime? since,
    int limit = 10,
  }) async {
    final total = listenSessions.seconds.sum();
    final query = selectOnly(listenSessions).join(
      [
        innerJoin(tracks, tracks.id.equalsExp(listenSessions.trackId)),
      ],
    );
    query.addColumns([tracks.id, tracks.title, tracks.artist,
      tracks.durationSeconds, tracks.thumbnailUrl, tracks.album, total]);
    query.groupBy([tracks.id]);
    query.orderBy([OrderingTerm.desc(total)]);
    query.limit(limit);
    if (since != null) {
      query.where(
        listenSessions.listenedAt.isBiggerThanValue(since),
      );
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        (
          Track(
            id: row.read(tracks.id)!,
            title: row.read(tracks.title) ?? '',
            artist: row.read(tracks.artist) ?? '',
            duration: row.read(tracks.durationSeconds) == null
                ? null
                : Duration(seconds: row.read(tracks.durationSeconds)!),
            thumbnailUrl: row.read(tracks.thumbnailUrl),
            album: row.read(tracks.album),
          ),
          row.read(total) ?? 0,
        ),
    ];
  }

  /// Segundos de escucha agrupados por artista, top [limit] primero.
  Future<List<(String, int)>> topListenedArtists({
    DateTime? since,
    int limit = 10,
  }) async {
    final total = listenSessions.seconds.sum();
    final query = selectOnly(listenSessions).join(
      [innerJoin(tracks, tracks.id.equalsExp(listenSessions.trackId))],
    );
    query.addColumns([tracks.artist, total]);
    query.groupBy([tracks.artist]);
    query.orderBy([OrderingTerm.desc(total)]);
    query.limit(limit);
    if (since != null) {
      query.where(listenSessions.listenedAt.isBiggerThanValue(since));
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        (row.read(tracks.artist) ?? '', row.read(total) ?? 0),
    ];
  }

  /// Segundos de escucha agrupados por playlist, top [limit] primero.
  /// Playlists borradas después caen fuera del join; filas sin playlist
  /// cuentan bajo el bucket "cola/sin playlist" con id -1.
  Future<List<RecapPlaylistEntry>> topListenedPlaylists({
    DateTime? since,
    int limit = 10,
  }) async {
    final total = listenSessions.seconds.sum();
    final query = selectOnly(listenSessions).join(
      [
        leftOuterJoin(
          playlists,
          playlists.id.equalsExp(listenSessions.playlistId),
        ),
      ],
    );
    query.addColumns([listenSessions.playlistId, playlists.name, playlists.coverUrl, total]);
    query.groupBy([listenSessions.playlistId, playlists.name, playlists.coverUrl]);
    query.orderBy([OrderingTerm.desc(total)]);
    query.limit(limit);
    if (since != null) {
      query.where(listenSessions.listenedAt.isBiggerThanValue(since));
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        RecapPlaylistEntry(
          playlistId: row.read(listenSessions.playlistId),
          name: row.read(playlists.name) ?? '',
          coverUrl: row.read(playlists.coverUrl),
          seconds: row.read(total) ?? 0,
        ),
    ];
  }

  // ── álbumes guardados (corazón en la página del álbum) ──────────────

  /// Álbumes guardados, el más reciente primero: sección de la biblioteca.
  Stream<List<YtmAlbum>> watchSavedAlbums() {
    return savedAlbums.select()
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              YtmAlbum(
                playlistId: r.id,
                title: r.title,
                thumbnailUrl: r.thumbnailUrl,
                year: r.year,
                isSingle: r.isSingle,
              ),
          ],
        );
  }

  /// Guarda (o re-guarda: actualiza metadatos y pasa al frente) un álbum.
  Future<void> saveAlbum(YtmAlbum album) {
    return into(savedAlbums).insertOnConflictUpdate(
      SavedAlbumsCompanion.insert(
        id: album.playlistId,
        title: album.title,
        thumbnailUrl: Value(album.thumbnailUrl),
        year: Value(album.year),
        isSingle: Value(album.isSingle),
        savedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Quita un álbum de los guardados (no-op si no estaba).
  Future<void> unsaveAlbum(String playlistId) {
    return (delete(savedAlbums)..where((u) => u.id.equals(playlistId))).go();
  }

  /// `true` si el playlistId está guardado (estado del corazón).
  Future<bool> isAlbumSaved(String playlistId) async {
    final row =
        await (select(savedAlbums)..where((u) => u.id.equals(playlistId)))
            .getSingleOrNull();
    return row != null;
  }

  // ── canciones de la biblioteca (tab "Canciones") ───────────────────
  /// Todas las canciones guardadas (historial + cacheadas), por título.
  /// Alimenta el tab "Canciones" de la biblioteca (móvil y sidebar).
  Stream<List<Track>> watchAllTracks({int limit = 1000}) {
    final query = tracks.select()
      ..orderBy([(t) => OrderingTerm.asc(t.title)])
      ..limit(limit);
    return query.watch().map(
      (rows) => [for (final r in rows) _trackFromRow(r)],
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────
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
