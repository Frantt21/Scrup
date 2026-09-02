import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';


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
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text(l10n.newPlaylist),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.playlistNameHint),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
            ),
          ],
        );
      },
    );
    if (!mounted || name == null || name.isEmpty) return;
    final db = context.read<AppDatabase>();
    final id = await db.createPlaylist(name);
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
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.85,
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

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: cs.surfaceContainerHighest,
                child: const Center(
                  child: Icon(Icons.queue_music_rounded, size: 48),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$trackCount ${trackCount == 1 ? "track" : "tracks"}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
