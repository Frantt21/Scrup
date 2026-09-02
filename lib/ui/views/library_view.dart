import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../widgets/cover_image.dart';
import '../widgets/create_playlist_dialog.dart';
import '../widgets/scrup_toasts.dart';


/// Mobile library view: all playlists displayed in a grid.
class LibraryView extends StatefulWidget {
  final ValueChanged<Playlist> onSelectPlaylist;

  const LibraryView({super.key, required this.onSelectPlaylist});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  late final Stream<List<Playlist>> _playlistsStream;
  late final Stream<Map<int, int>> _countsStream;
  StreamSubscription<List<Playlist>>? _playlistsSub;
  StreamSubscription<Map<int, int>>? _countsSub;
  List<Playlist> _playlists = const [];
  Map<int, int> _counts = const {};

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _countsSub?.cancel();
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    // Mismo diálogo que desktop (sidebar): flujo compartido.
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
    final pl = await db.getPlaylist(id);
    if (pl != null && mounted) widget.onSelectPlaylist(pl);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  l10n.library,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add_rounded),
                  tooltip: l10n.newPlaylist,
                ),
              ],
            ),
          ),
        ),
        if (_playlists.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.library_music_rounded,
                      size: 64,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
                  const SizedBox(height: 12),
                  Text(l10n.noPlaylists,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.9,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _PlaylistGridCard(
                  playlist: _playlists[i],
                  trackCount: _counts[_playlists[i].id] ?? 0,
                  onTap: () => widget.onSelectPlaylist(_playlists[i]),
                ),
                childCount: _playlists.length,
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}

class _PlaylistGridCard extends StatelessWidget {
  final Playlist playlist;
  final int trackCount;
  final VoidCallback onTap;

  const _PlaylistGridCard({
    required this.playlist,
    required this.trackCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final favorites = playlist.isFavorites;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CoverImage(
                source: playlist.coverUrl,
                cacheWidth: 200,
                fallback: favorites
                    ? _favoritesFallback(cs)
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              cs.surfaceContainerHigh,
                              cs.surfaceContainer,
                            ],
                          ),
                        ),
                        child: Icon(
                          Icons.queue_music_rounded,
                          size: 28,
                          color: cs.primary.withValues(alpha: 0.45),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: favorites ? cs.primary : null,
            ),
          ),
          Text(
            l10n.songCount(trackCount),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _favoritesFallback(ColorScheme cs) {
    final primary = cs.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.45),
            primary.withValues(alpha: 0.15),
            cs.surfaceContainer,
          ],
        ),
      ),
      child: Icon(Icons.favorite_rounded, size: 28, color: primary),
    );
  }
}
