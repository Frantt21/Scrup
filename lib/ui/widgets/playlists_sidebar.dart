import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/player_service.dart';
import '../../services/settings_store.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/ytmusic_service.dart' show YtmAlbum;
import '../playback.dart';
import '../playlist_actions.dart';
import 'context_menu_item.dart';
import 'cover_image.dart';
import 'create_playlist_dialog.dart';
import 'now_playing_bars.dart';
import 'scrup_toasts.dart';
import 'spotify_import_dialog.dart';
import 'track_tile.dart';

const double kSidebarWidth = 300;

/// Sidebar resize limits (desktop drag on the inner edge).
const double kSidebarMinWidth = 200;
const double kSidebarMaxWidth = 460;

/// Ancho de las cards del sidebar (biblioteca) en modo cuadrícula: 2 columnas,
/// padding lateral 10 y spacing 10 → (ancho − 30) / 2. Home reutiliza este
/// tamaño en sus "Recientes" para que ambos compartan el mismo ritmo visual.
double libraryGridCardWidth(double sidebarWidth) => (sidebarWidth - 30) / 2;

/// Acento de la playlist: extraído de su propia portada (fallback primary).
Color playlistAccent(BuildContext context, Playlist playlist, ThemeData theme) {
  final url = playlist.coverUrl;
  if (url != null && url.isNotEmpty) {
    final trio = context.read<PaletteCacheStore>().getTrio(url);
    final accent = trio == null ? null : ArtworkPaletteService.accentFromTrio(trio);
    if (accent != null) return accent;
  }
  return theme.colorScheme.primary;
}

/// Sección visible en la biblioteca lateral de escritorio.
enum _LibrarySection { all, playlists, albums, songs }

/// Floating glass sidebar showing the library (playlists, saved albums and
/// saved songs) with a list/grid toggle and section tabs.
class PlaylistsSidebar extends StatefulWidget {
  final int? openPlaylistId;
  final ValueChanged<Playlist?> onSelectPlaylist;

  /// Abre un álbum guardado (mismo screen de artista que home/móvil).
  final ValueChanged<YtmAlbum>? onOpenAlbum;

  /// Current width (owned by AppShell so it persists); `null` = default.
  final double? width;

  /// Dragging the inner edge reports the new width live (AppShell updates
  /// state → the center container absorbs the difference automatically).
  final ValueChanged<double>? onWidthDrag;

  /// Drag finished → persist the width once.
  final VoidCallback? onWidthDragEnd;

  const PlaylistsSidebar({
    super.key,
    required this.openPlaylistId,
    required this.onSelectPlaylist,
    this.onOpenAlbum,
    this.width,
    this.onWidthDrag,
    this.onWidthDragEnd,
  });

  @override
  State<PlaylistsSidebar> createState() => _PlaylistsSidebarState();
}

class _PlaylistsSidebarState extends State<PlaylistsSidebar> {
  late final Stream<List<Playlist>> _playlistsStream;
  late final Stream<Map<int, int>> _countsStream;
  StreamSubscription<List<Playlist>>? _playlistsSub;
  StreamSubscription<Map<int, int>>? _countsSub;
  StreamSubscription<bool>? _playingSub;
  List<Playlist> _playlists = const [];
  Map<int, int> _counts = const {};

  // Biblioteca: álbumes guardados (corazón) y canciones de la BD.
  StreamSubscription<List<YtmAlbum>>? _albumsSub;
  List<YtmAlbum> _savedAlbums = const [];
  StreamSubscription<List<Track>>? _songsSub;
  List<Track> _songs = const [];
  StreamSubscription<Track?>? _trackSub;
  String? _activeTrackId;

  _LibrarySection _section = _LibrarySection.all;

  int? _activePlaylistId;
  bool _playing = false;
  late final PlayerService _player;

  bool _gridMode = false;
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _loadGridMode();
    final db = context.read<AppDatabase>();
    _playlistsStream = db.watchPlaylists();
    _playlistsSub = _playlistsStream.listen((playlists) {
      if (!mounted) return;
      setState(() => _playlists = playlists);
    });
    _countsStream = db.watchPlaylistTrackCounts();
    _countsSub = _countsStream.listen((counts) {
      if (!mounted) return;
      setState(() => _counts = counts);
    });
    _albumsSub = db.watchSavedAlbums().listen((albums) {
      if (!mounted) return;
      setState(() => _savedAlbums = albums);
    });
    _songsSub = db.watchAllTracks().listen((songs) {
      if (!mounted) return;
      setState(() => _songs = songs);
    });
    _player = context.read<PlayerService>();
    _activePlaylistId = _player.activePlaylistId.value;
    _playing = _player.isPlaying;
    _activeTrackId = _player.currentTrackValue?.id;
    _player.activePlaylistId.addListener(_onActivePlaylistChanged);
    _playingSub = _player.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
    _trackSub = _player.currentTrack.listen((t) {
      if (!mounted) return;
      setState(() => _activeTrackId = t?.id);
    });
  }

  void _onActivePlaylistChanged() {
    if (!mounted) return;
    setState(() => _activePlaylistId = _player.activePlaylistId.value);
  }

  /// Menú contextual (clic derecho) sobre una playlist: reproducir y
  /// añadir a favoritos la pista EN REPRODUCCIÓN de esa playlist (si la
  /// hay). La eliminación sigue en el icono de hover de cada fila.
  Future<void> _showPlaylistMenu(Playlist playlist, Offset position) async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final current = _player.currentTrackValue;
    final fromThis = current != null && _activePlaylistId == playlist.id;
    final isFav = current != null
        ? (await db.playlistIdsContainingTrack(current.id)).contains(
            await db.ensureFavoritesPlaylist(),
          )
        : false;
    if (!mounted) return;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      clipBehavior: Clip.antiAlias,
      items: [
        ContextMenuItem(
          value: 'play',
          icon: Icons.play_arrow_rounded,
          label: l10n.play,
        ),
        if (fromThis)
          ContextMenuItem(
            value: 'fav',
            icon: isFav
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: isFav
                ? l10n.removeFromFavorites
                : l10n.addToFavorites,
          ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'play') {
      widget.onSelectPlaylist(playlist);
    } else if (action == 'fav' && current != null) {
      await toggleTrackFavorite(context, current);
    }
  }

  Future<void> _loadGridMode() async {
    try {
      final saved = await context.read<SettingsStore>().loadSidebarGridMode();
      if (!mounted || saved == null || _userToggled) return;
      setState(() => _gridMode = saved);
    } catch (_) {}
  }

  void _toggleGridMode(bool grid) {
    _userToggled = true;
    setState(() => _gridMode = grid);
    unawaited(context.read<SettingsStore>().saveSidebarGridMode(grid));
  }

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _countsSub?.cancel();
    _playingSub?.cancel();
    _albumsSub?.cancel();
    _songsSub?.cancel();
    _trackSub?.cancel();
    _player.activePlaylistId.removeListener(_onActivePlaylistChanged);
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final data =
        await showDialog<
          ({String name, String? description, String? imagePath})
        >(context: context, builder: (_) => const CreatePlaylistDialog());
    if (data == null || !mounted) return;
    final name = data.name.trim();
    if (name.isEmpty) return;
    final int id;
    try {
      id = await db.createPlaylist(name);
    } catch (_) {
      if (!mounted) return;
      showScrupToast(l10n.cantCreatePlaylist, kind: ScrupToastKind.error);
      return;
    }
    final description = data.description;
    if (description != null && description.isNotEmpty) {
      try {
        await db.setPlaylistDescription(id, description);
      } catch (_) {}
    }
    final imagePath = data.imagePath;
    if (imagePath != null) {
      try {
        final dest = await copyPlaylistCoverToAppDir(id, imagePath);
        await db.setPlaylistCover(id, dest);
      } catch (_) {}
    }
    showScrupToast(l10n.playlistCreated(name), kind: ScrupToastKind.success);
    if (!mounted) return;
    final playlist = await db.getPlaylist(id);
    if (mounted && playlist != null) {
      widget.onSelectPlaylist(playlist);
    }
  }

  Future<void> _importFromSpotify() async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final data = await showDialog<({String name, List<Track> tracks})>(
      context: context,
      builder: (_) => const SpotifyImportDialog(),
    );
    if (data == null || !mounted) return;
    final name = data.name.trim();
    if (name.isEmpty || data.tracks.isEmpty) return;
    final int id;
    try {
      id = await db.createPlaylist(name);
    } catch (_) {
      if (!mounted) return;
      showScrupToast(l10n.cantCreatePlaylist, kind: ScrupToastKind.error);
      return;
    }
    for (final track in data.tracks) {
      try {
        // Dedupe interno: si ya estaba, no la duplica.
        await db.addToPlaylist(id, track);
      } catch (_) {}
    }
    if (!mounted) return;
    showScrupToast(l10n.playlistCreated(name), kind: ScrupToastKind.success);
    final playlist = await db.getPlaylist(id);
    if (mounted && playlist != null) {
      widget.onSelectPlaylist(playlist);
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    if (playlist.isFavorites) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deletePlaylistTitle),
        content: Text(l10n.confirmDeletePlaylist(playlist.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await db.deletePlaylist(playlist.id);
    final cover = playlist.coverUrl;
    if (cover != null && CoverImage.isLocalPath(cover)) {
      final file = File(cover);
      if (await file.exists()) {
        try {
          await file.delete();
    } catch (_) {}
      }
    }
    if (widget.openPlaylistId == playlist.id) {
      widget.onSelectPlaylist(null);
    }
    if (!mounted) return;
    showScrupToast(l10n.playlistDeleted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return _SidebarResizeHandle(
      width: widget.width ?? kSidebarWidth,
      onWidthDrag: widget.onWidthDrag,
      onWidthDragEnd: widget.onWidthDragEnd,
      child: Container(
      width: widget.width ?? kSidebarWidth,
      margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
      // Sombra exterior (fuera del clip para que no se recorte)
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.72,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.library,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      // Acciones de cabecera: importar y crear (antes
                      // vivían dentro del contenido como tiles/celdas).
                      IconButton(
                        icon: const Icon(Icons.sync_alt_rounded, size: 20),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.importSpotify,
                        onPressed: _importFromSpotify,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_rounded, size: 22),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.newPlaylist,
                        onPressed: _createPlaylist,
                      ),
                      if (_section != _LibrarySection.songs)
                        _ViewToggle(
                          gridMode: _gridMode,
                          onChanged: _toggleGridMode,
                        ),
                    ],
                  ),
                ),
                // Tabs de sección: Todo / Playlists / Álbumes / Canciones.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: _SectionTabs(
                    section: _section,
                    onChanged: (s) => setState(() => _section = s),
                  ),
                ),
                Expanded(child: _buildBody(theme)),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        if (_playlists.isEmpty) _emptyState(theme),
        for (final playlist in _playlists)
          _PlaylistRow(
            playlist: playlist,
            count: _counts[playlist.id] ?? 0,
            selected: playlist.id == widget.openPlaylistId,
            onTap: () => widget.onSelectPlaylist(playlist),
            onMenu: (pos) => _showPlaylistMenu(playlist, pos),
            onDelete: () => _deletePlaylist(playlist),
            // Favoritos: diseño especial con corazón y sin borrar.
            showDelete: !playlist.isFavorites,
            nowPlaying: _activePlaylistId == playlist.id,
            isPlaying: _playing,
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildGrid(ThemeData theme) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: _playlists.length,
      itemBuilder: (context, i) {
        final playlist = _playlists[i];
        return _PlaylistGridCell(
          playlist: playlist,
          count: _counts[playlist.id] ?? 0,
          selected: playlist.id == widget.openPlaylistId,
          onTap: () => widget.onSelectPlaylist(playlist),
          onMenu: (pos) => _showPlaylistMenu(playlist, pos),
          onDelete: () => _deletePlaylist(playlist),
          // Favoritos: diseño especial con corazón y sin borrar.
          showDelete: !playlist.isFavorites,
          // Indicador: solo en la playlist que se está reproduciendo.
          nowPlaying: _activePlaylistId == playlist.id,
          isPlaying: _playing,
        );
      },
    );
  }

  Widget _buildBody(ThemeData theme) {
    switch (_section) {
      case _LibrarySection.playlists:
        return _gridMode ? _buildGrid(theme) : _buildList(theme);
      case _LibrarySection.albums:
        return _buildAlbums(theme);
      case _LibrarySection.songs:
        return _buildSongs(theme);
      case _LibrarySection.all:
        return _gridMode ? _buildAllGrid(theme) : _buildAllList(theme);
    }
  }

  // ── Álbumes guardados ───────────────────────────────────────────────
  Widget _buildAlbums(ThemeData theme) {
    if (_savedAlbums.isEmpty) {
      return _emptyHint(
        theme,
        Icons.album_rounded,
        AppLocalizations.of(context).savedAlbumsTitle,
      );
    }
    if (_gridMode) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.78,
        ),
        itemCount: _savedAlbums.length,
        itemBuilder: (context, i) => _SavedAlbumCell(
          album: _savedAlbums[i],
          onTap: () => widget.onOpenAlbum?.call(_savedAlbums[i]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        for (final album in _savedAlbums)
          _SavedAlbumRow(
            album: album,
            onTap: () => widget.onOpenAlbum?.call(album),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  // ── Canciones ───────────────────────────────────────────────────────
  Widget _buildSongs(ThemeData theme) {
    if (_songs.isEmpty) {
      return _emptyHint(
        theme,
        Icons.music_note_rounded,
        AppLocalizations.of(context).noPlaylists,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      itemCount: _songs.length,
      itemBuilder: (context, i) => TrackTile(
        track: _songs[i],
        isCurrent: _songs[i].id == _activeTrackId,
        isPlaying: _playing,
        showDuration: false,
        onPlay: () => unawaited(playQueue(context, _songs, startIndex: i)),
      ),
    );
  }

  // ── Todo (playlists + álbumes) ──────────────────────────────────────
  Widget _buildAllList(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        if (_playlists.isEmpty && _savedAlbums.isEmpty) _emptyState(theme),
        for (final playlist in _playlists)
          _PlaylistRow(
            playlist: playlist,
            count: _counts[playlist.id] ?? 0,
            selected: playlist.id == widget.openPlaylistId,
            onTap: () => widget.onSelectPlaylist(playlist),
            onMenu: (pos) => _showPlaylistMenu(playlist, pos),
            onDelete: () => _deletePlaylist(playlist),
            showDelete: !playlist.isFavorites,
            nowPlaying: _activePlaylistId == playlist.id,
            isPlaying: _playing,
          ),
        if (_savedAlbums.isNotEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            child: Text(
              AppLocalizations.of(context).libraryTabAlbums,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final album in _savedAlbums)
            _SavedAlbumRow(
              album: album,
              onTap: () => widget.onOpenAlbum?.call(album),
            ),
        ],
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildAllGrid(ThemeData theme) {
    final total = _playlists.length + _savedAlbums.length;
    if (total == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        children: [_emptyState(theme)],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: total,
      itemBuilder: (context, i) {
        if (i < _playlists.length) {
          final playlist = _playlists[i];
          return _PlaylistGridCell(
            playlist: playlist,
            count: _counts[playlist.id] ?? 0,
            selected: playlist.id == widget.openPlaylistId,
            onTap: () => widget.onSelectPlaylist(playlist),
            onMenu: (pos) => _showPlaylistMenu(playlist, pos),
            onDelete: () => _deletePlaylist(playlist),
            showDelete: !playlist.isFavorites,
            nowPlaying: _activePlaylistId == playlist.id,
            isPlaying: _playing,
          );
        }
        final album = _savedAlbums[i - _playlists.length];
        return _SavedAlbumCell(
          album: album,
          onTap: () => widget.onOpenAlbum?.call(album),
        );
      },
    );
  }

  Widget _emptyHint(ThemeData theme, IconData icon, String text) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        Icon(
          icon,
          size: 32,
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 8),
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: 32,
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).noPlaylists,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            AppLocalizations.of(context).createOneHere,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact list/grid toggle chip.
class _ViewToggle extends StatelessWidget {
  final bool gridMode;
  final ValueChanged<bool> onChanged;

  const _ViewToggle({required this.gridMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(
            context: context,
            icon: Icons.view_list_rounded,
            tooltip: AppLocalizations.of(context).listViewTooltip,
            active: !gridMode,
            onTap: () => onChanged(false),
          ),
          _seg(
            context: context,
            icon: Icons.grid_view_rounded,
            tooltip: AppLocalizations.of(context).gridViewTooltip,
            active: gridMode,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }

  Widget _seg({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: active
          ? theme.colorScheme.primary.withValues(alpha: 0.25)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Icon(
              icon,
              size: 17,
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Playlist row (list view) with thumbnail, name, count and delete on hover.
class _PlaylistRow extends StatefulWidget {
  final Playlist playlist;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// Clic derecho: menú contextual (reproducir / favorito).
  final void Function(Offset position)? onMenu;

  /// `false` en Favoritos: no se muestra el botón de borrar.
  final bool showDelete;

  /// Una canción de esta playlist está en el reproductor.
  final bool nowPlaying;

  /// Si la canción en reproducción está sonando (para animar el indicador).
  final bool isPlaying;

  const _PlaylistRow({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    this.onMenu,
    this.showDelete = true,
    this.nowPlaying = false,
    this.isPlaying = false,
  });

  @override
  State<_PlaylistRow> createState() => _PlaylistRowState();
}

class _PlaylistRowState extends State<_PlaylistRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = widget.playlist;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: widget.onMenu == null
            ? null
            : (d) => widget.onMenu!(d.globalPosition),
        child: Material(
        color: widget.selected
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _thumb(theme),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: widget.selected
                                    ? theme.colorScheme.primary
                                    : (playlist.isFavorites
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurface),
                              ),
                            ),
                          ),
                          if (widget.nowPlaying) ...[
                            const SizedBox(width: 6),
                            NowPlayingBars(
                              active: widget.isPlaying,
                              size: 11,
                              color: playlistAccent(context, playlist, theme),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        AppLocalizations.of(context).songCount(widget.count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.showDelete)
                  SizedBox(
                    width: 32,
                    child: _hovered
                        ? IconButton(
                            icon: const Icon(Icons.delete_rounded, size: 18),
                            visualDensity: VisualDensity.compact,
                            tooltip: AppLocalizations.of(context).delete,
                            color: theme.colorScheme.onSurfaceVariant,
                            onPressed: widget.onDelete,
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _thumb(ThemeData theme) {
    final favorites = widget.playlist.isFavorites;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 40,
        height: 40,
        child: CoverImage(
          source: widget.playlist.coverUrl,
          cacheWidth: 120,
          fallback: favorites
              ? _favoritesFallback(theme)
              : Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.surfaceContainerHigh,
                        theme.colorScheme.surfaceContainer,
                      ],
                    ),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    size: 18,
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _favoritesFallback(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.45),
            primary.withValues(alpha: 0.15),
            theme.colorScheme.surfaceContainer,
          ],
        ),
      ),
      child: Icon(Icons.favorite_rounded, size: 18, color: primary),
    );
  }
}

/// Playlist grid cell with cover, name, count and delete on hover.
class _PlaylistGridCell extends StatefulWidget {
  final Playlist playlist;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// Clic derecho: menú contextual (reproducir / favorito).
  final void Function(Offset position)? onMenu;

  final bool showDelete;
  final bool nowPlaying;
  final bool isPlaying;

  const _PlaylistGridCell({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    this.onMenu,
    this.showDelete = true,
    this.nowPlaying = false,
    this.isPlaying = false,
  });

  @override
  State<_PlaylistGridCell> createState() => _PlaylistGridCellState();
}

class _PlaylistGridCellState extends State<_PlaylistGridCell> {
  bool _hovered = false;

  Widget _favoritesFallback(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.50),
            primary.withValues(alpha: 0.18),
            theme.colorScheme.surfaceContainer,
          ],
        ),
      ),
      child: Icon(Icons.favorite_rounded, size: 32, color: primary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = widget.playlist;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onMenu == null
            ? null
            : (d) => widget.onMenu!(d.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CoverImage(
                      source: playlist.coverUrl,
                      cacheWidth: 200,
                      fallback: playlist.isFavorites
                          ? _favoritesFallback(theme)
                          : Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    theme.colorScheme.surfaceContainerHigh,
                                    theme.colorScheme.surfaceContainer,
                                  ],
                                ),
                              ),
                              child: Icon(
                                Icons.queue_music_rounded,
                                size: 28,
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                            ),
                    ),
                  ),
                  if (_hovered || widget.selected)
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: playlistAccent(
                              context,
                              playlist,
                              theme,
                            ).withValues(alpha: widget.selected ? 0.9 : 0.5),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  if (_hovered && widget.showDelete)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onDelete,
                          mouseCursor: SystemMouseCursors.click,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.nowPlaying)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: NowPlayingBars(
                        active: widget.isPlaying,
                        size: 10,
                        color: playlistAccent(context, playlist, theme),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: widget.selected
                    ? theme.colorScheme.primary
                    : (playlist.isFavorites
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface),
              ),
            ),
            Text(
              AppLocalizations.of(context).songCount(widget.count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact segmented tabs for the library sections (Todo / Playlists /
/// Álbumes / Canciones). Cuatro segmentos iguales para que quepan en el
/// ancho del sidebar sin desbordar.
class _SectionTabs extends StatelessWidget {
  final _LibrarySection section;
  final ValueChanged<_LibrarySection> onChanged;

  const _SectionTabs({required this.section, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = <(_LibrarySection, String)>[
      (_LibrarySection.all, l10n.searchFilterAll),
      (_LibrarySection.playlists, l10n.playlistsTitle),
      (_LibrarySection.albums, l10n.libraryTabAlbums),
      (_LibrarySection.songs, l10n.libraryTabSongs),
    ];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Row(
        children: [
          for (final (value, label) in labels)
            Expanded(
              child: _seg(context, value, label),
            ),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, _LibrarySection value, String label) {
    final theme = Theme.of(context);
    final active = value == section;
    return Material(
      color: active
          ? theme.colorScheme.primary.withValues(alpha: 0.25)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(value),
        mouseCursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fila de un álbum guardado (modo lista del sidebar).
class _SavedAlbumRow extends StatelessWidget {
  final YtmAlbum album;
  final VoidCallback onTap;

  const _SavedAlbumRow({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CoverImage(
                    source: album.thumbnailUrl,
                    cacheWidth: 120,
                    fallback: _albumFallback(theme, 18),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      album.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      album.year ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Celda de un álbum guardado (modo cuadrícula del sidebar).
class _SavedAlbumCell extends StatelessWidget {
  final YtmAlbum album;
  final VoidCallback onTap;

  const _SavedAlbumCell({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CoverImage(
                  source: album.thumbnailUrl,
                  cacheWidth: 200,
                  fallback: _albumFallback(theme, 28),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              album.year ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _albumFallback(ThemeData theme, double iconSize) {
  return Container(
    color: theme.colorScheme.surfaceContainerHigh,
    child: Icon(
      Icons.album_rounded,
      size: iconSize,
      color: theme.colorScheme.primary.withValues(alpha: 0.45),
    ),
  );
}

/// Button to create or import a new playlist (list view).

/// Inner-edge resize handle for the sidebar: a 6px drag strip on the right
/// edge. Dragging reports the new width live (clamped); hover shows a thin
/// accent hint line. Lives OUTSIDE the clipped glass so the hit area spans
/// the full height.
class _SidebarResizeHandle extends StatelessWidget {
  final double width;
  final ValueChanged<double>? onWidthDrag;
  final VoidCallback? onWidthDragEnd;
  final Widget child;

  const _SidebarResizeHandle({
    required this.width,
    required this.child,
    this.onWidthDrag,
    this.onWidthDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 12,
          bottom: 12,
          right: 0,
          width: 8,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            onHover: (_) {},
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) {
                final next = (width + d.delta.dx)
                    .clamp(kSidebarMinWidth, kSidebarMaxWidth);
                onWidthDrag?.call(next);
              },
              onHorizontalDragEnd: (_) => onWidthDragEnd?.call(),
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 2,
                  child: Center(
                    child: Container(
                      width: 2,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.0),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
