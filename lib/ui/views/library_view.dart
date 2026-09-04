import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../widgets/cover_image.dart';
import '../widgets/create_playlist_dialog.dart';
import '../widgets/scrup_toasts.dart';
import '../widgets/spotify_import_dialog.dart';


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

  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Playlists filtradas por la consulta de búsqueda (insensible a acentos).
  List<Playlist> get _filtered {
    final q = _normQuery(_searchCtrl.text.trim());
    if (q.isEmpty) return _playlists;
    return [
      for (final p in _playlists)
        if (_normQuery(p.name).contains(q)) p,
    ];
  }

  static String _normQuery(String s) {
    var out = s.toLowerCase();
    const accents = {
      'á': 'a', 'à': 'a', 'é': 'e', 'è': 'e', 'í': 'i', 'ó': 'o',
      'ú': 'u', 'ü': 'u', 'ñ': 'n',
    };
    accents.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchCtrl.clear();
    setState(() => _searchOpen = false);
  }

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
    _searchCtrl.dispose();
    _searchFocus.dispose();
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
    final pl = await db.getPlaylist(id);
    if (pl != null && mounted) widget.onSelectPlaylist(pl);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final filtered = _filtered;
    final searching = _searchOpen && _searchCtrl.text.trim().isNotEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.15),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: _searchOpen
                  ? Row(
                      key: const ValueKey('search_open'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton.filledTonal(
                          onPressed: _closeSearch,
                          icon: const Icon(Icons.arrow_back_rounded),
                          tooltip: l10n.searchHint,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 40,
                            child: TextField(
                              controller: _searchCtrl,
                              focusNode: _searchFocus,
                              onChanged: (_) => setState(() {}),
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                hintText: l10n.searchPlaylists,
                                prefixIcon: const Icon(Icons.search_rounded),
                                filled: true,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      key: const ValueKey('header_normal'),
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            l10n.library,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          onPressed: _openSearch,
                          icon: const Icon(Icons.search_rounded),
                          tooltip: l10n.searchHint,
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: _importFromSpotify,
                          icon: const Icon(Icons.sync_alt_rounded),
                          tooltip: l10n.importSpotify,
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: _createPlaylist,
                          icon: const Icon(Icons.add_rounded),
                          tooltip: l10n.newPlaylist,
                        ),
                      ],
                    ),
            ),
          ),
        ),
        if (filtered.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    searching
                        ? Icons.search_off_rounded
                        : Icons.library_music_rounded,
                    size: 64,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    searching ? l10n.noMatchingPlaylists : l10n.noPlaylists,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                // 2 columnas: tarjetas grandes y simétricas que cubren el
                // ancho. Portada 1:1 + bloque de texto debajo.
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent:
                    (MediaQuery.sizeOf(context).width - 12 * 2 - 12) /
                        2 +
                    48,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _PlaylistGridCard(
                  playlist: filtered[i],
                  trackCount: _counts[filtered[i].id] ?? 0,
                  onTap: () => widget.onSelectPlaylist(filtered[i]),
                ),
                childCount: filtered.length,
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
          // Portada siempre 1:1, ancho de la celda.
          AspectRatio(
            aspectRatio: 1,
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
        // Card plana (sin degradado), con un tinte sutil del acento.
        color: primary.withValues(alpha: 0.18),
      ),
      child: Icon(Icons.favorite_rounded, size: 28, color: primary),
    );
  }
}
