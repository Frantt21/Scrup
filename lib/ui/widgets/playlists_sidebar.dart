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
import 'cover_image.dart';
import 'create_playlist_dialog.dart';
import 'now_playing_bars.dart';
import 'scrup_toasts.dart';
import 'spotify_import_dialog.dart';

const double kSidebarWidth = 250;

/// Floating glass sidebar showing all playlists with list/grid toggle.
class PlaylistsSidebar extends StatefulWidget {
  final int? openPlaylistId;
  final ValueChanged<Playlist?> onSelectPlaylist;

  const PlaylistsSidebar({
    super.key,
    required this.openPlaylistId,
    required this.onSelectPlaylist,
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
    _player = context.read<PlayerService>();
    _activePlaylistId = _player.activePlaylistId.value;
    _playing = _player.isPlaying;
    _player.activePlaylistId.addListener(_onActivePlaylistChanged);
    _playingSub = _player.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
  }

  void _onActivePlaylistChanged() {
    if (!mounted) return;
    setState(() => _activePlaylistId = _player.activePlaylistId.value);
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

    return Container(
      width: kSidebarWidth,
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
                          l10n.playlistsTitle,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _ViewToggle(
                        gridMode: _gridMode,
                        onChanged: _toggleGridMode,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _gridMode ? _buildGrid(theme) : _buildList(theme),
                ),
              ],
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
            onDelete: () => _deletePlaylist(playlist),
            // Favoritos: diseño especial con corazón y sin borrar.
            showDelete: !playlist.isFavorites,
            nowPlaying: _activePlaylistId == playlist.id,
            isPlaying: _playing,
          ),
        const SizedBox(height: 4),
        _CreatePlaylistTile(onTap: _createPlaylist),
        _CreatePlaylistTile(
          onTap: _importFromSpotify,
          icon: Icons.sync_alt_rounded,
          label: AppLocalizations.of(context).importSpotify,
        ),
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
      itemCount: _playlists.length + 2,
      itemBuilder: (context, i) {
        if (i == _playlists.length) {
          return _CreateGridCell(onTap: _createPlaylist);
        }
        if (i == _playlists.length + 1) {
          return _CreateGridCell(
            onTap: _importFromSpotify,
            icon: Icons.sync_alt_rounded,
            label: AppLocalizations.of(context).importSpotify,
          );
        }
        final playlist = _playlists[i];
        return _PlaylistGridCell(
          playlist: playlist,
          count: _counts[playlist.id] ?? 0,
          selected: playlist.id == widget.openPlaylistId,
          onTap: () => widget.onSelectPlaylist(playlist),
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
                            NowPlayingBars(active: widget.isPlaying, size: 11),
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

  final bool showDelete;
  final bool nowPlaying;
  final bool isPlaying;

  const _PlaylistGridCell({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
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
                            color: theme.colorScheme.primary.withValues(
                              alpha: widget.selected ? 0.9 : 0.5,
                            ),
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
                      child: NowPlayingBars(active: widget.isPlaying, size: 10),
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

/// Button to create or import a new playlist (list view).
class _CreatePlaylistTile extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final String? label;

  const _CreatePlaylistTile({
    required this.onTap,
    this.icon = Icons.add_rounded,
    this.label,
  });

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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label ?? AppLocalizations.of(context).newPlaylist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Button to create or import a new playlist (grid view).
class _CreateGridCell extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final String? label;

  const _CreateGridCell({
    required this.onTap,
    this.icon = Icons.add_rounded,
    this.label,
  });

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
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                ),
                child: Center(
                  child: Icon(icon, size: 32, color: theme.colorScheme.primary),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label ?? AppLocalizations.of(context).newPlaylist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
            Text(
              AppLocalizations.of(context).newPlaylistHint,
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