import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/player_service.dart';
import '../../services/ytmusic_service.dart' show YtmAlbum;
import '../playback.dart';
import '../widgets/cover_image.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/playlists_sidebar.dart' show playlistAccent;
import '../widgets/create_playlist_dialog.dart';
import '../widgets/screen_header.dart';
import '../widgets/scrup_toasts.dart';
import '../widgets/spotify_import_dialog.dart';
import '../widgets/track_tile.dart';

/// Sección visible en la biblioteca móvil.
enum _LibraryTab { all, playlists, albums, songs }

/// Mobile library view: all playlists displayed in a grid.
class LibraryView extends StatefulWidget {
  final ValueChanged<Playlist> onSelectPlaylist;

  /// Abre un álbum guardado (mismo screen que home: artista con álbum
  /// embebido). Opcional para no romper previews/tests.
  final ValueChanged<YtmAlbum>? onOpenAlbum;

  const LibraryView({
    super.key,
    required this.onSelectPlaylist,
    this.onOpenAlbum,
  });

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  late final Stream<List<Playlist>> _playlistsStream;
  late final Stream<Map<int, int>> _countsStream;
  StreamSubscription<List<Playlist>>? _playlistsSub;
  StreamSubscription<Map<int, int>>? _countsSub;
  StreamSubscription<bool>? _playingSub;
  List<Playlist> _playlists = const [];
  Map<int, int> _counts = const {};

  // Álbumes guardados (corazón en la página del álbum).
  Stream<List<YtmAlbum>>? _albumsStream;
  StreamSubscription<List<YtmAlbum>>? _albumsSub;
  List<YtmAlbum> _savedAlbums = const [];

  // Canciones de la biblioteca (tab "Canciones").
  StreamSubscription<List<Track>>? _songsSub;
  List<Track> _songs = const [];
  StreamSubscription<Track?>? _trackSub;
  String? _activeTrackId;

  _LibraryTab _tab = _LibraryTab.all;

  // Para el indicador "now playing" en las cards.
  int? _activePlaylistId;
  bool _playing = false;

  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Playlists filtered by the search query (accent-insensitive).
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
      'á': 'a',
      'à': 'a',
      'é': 'e',
      'è': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
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
    _albumsStream = db.watchSavedAlbums();
    _albumsSub = _albumsStream?.listen((albums) {
      if (!mounted) return;
      setState(() => _savedAlbums = albums);
    });
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
    _songsSub = db.watchAllTracks().listen((songs) {
      if (!mounted) return;
      setState(() => _songs = songs);
    });
    final player = context.read<PlayerService>();
    _activePlaylistId = player.activePlaylistId.value;
    _activeTrackId = player.currentTrackValue?.id;
    player.activePlaylistId.addListener(_onActiveChanged);
    _playingSub = player.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    });
    _trackSub = player.currentTrack.listen((t) {
      if (mounted) setState(() => _activeTrackId = t?.id);
    });
  }

  void _onActiveChanged() {
    if (mounted) {
      setState(
        () => _activePlaylistId = context.read<PlayerService>().activePlaylistId.value,
      );
    }
  }

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _countsSub?.cancel();
    _playingSub?.cancel();
    _albumsSub?.cancel();
    _songsSub?.cancel();
    _trackSub?.cancel();
    if (mounted) {
      context.read<PlayerService>().activePlaylistId.removeListener(
        _onActiveChanged,
      );
    }
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
    // Con búsqueda activa los resultados (playlists) mandan sobre el tab.
    final tab = searching ? _LibraryTab.playlists : _tab;

    return CustomScrollView(
      slivers: [
        // Header FIJO (pinned, transparente) igual al de home: mismo inset
        // superior, mismos paddings y botones tonales de 40dp — el contenido
        // pasa por detrás al scrollear.
        SliverPersistentHeader(
          pinned: true,
          floating: false,
          delegate: ScreenHeaderDelegate(
            topInset: MediaQuery.paddingOf(context).top,
            // Los tabs viajan pinned bajo el título; durante la búsqueda se
            // ocultan (los resultados mandan).
            bottom: _searchOpen ? null : _buildTabs(),
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
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        headerActionButton(
                          context,
                          icon: Icons.arrow_back_rounded,
                          tooltip: l10n.searchHint,
                          onTap: _closeSearch,
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
                        headerActionButton(
                          context,
                          icon: Icons.search_rounded,
                          tooltip: l10n.searchHint,
                          onTap: _openSearch,
                        ),
                        const SizedBox(width: 8),
                        headerActionButton(
                          context,
                          icon: Icons.sync_alt_rounded,
                          tooltip: l10n.importSpotify,
                          onTap: _importFromSpotify,
                        ),
                        const SizedBox(width: 8),
                        headerActionButton(
                          context,
                          icon: Icons.add_rounded,
                          tooltip: l10n.newPlaylist,
                          onTap: _createPlaylist,
                        ),
                      ],
                    ),
            ),
          ),
        ),
        ..._buildSectionSlivers(l10n, theme, cs, tab, filtered, searching),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  /// Slivers de contenido según el tab activo (o los resultados de búsqueda).
  List<Widget> _buildSectionSlivers(
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme cs,
    _LibraryTab tab,
    List<Playlist> filtered,
    bool searching,
  ) {
    if (searching) {
      return filtered.isEmpty
          ? [_emptySliver(cs, theme, searching: true)]
          : [_playlistsGrid(filtered)];
    }
    switch (tab) {
      case _LibraryTab.all:
        if (filtered.isEmpty && _savedAlbums.isEmpty) {
          return [_emptySliver(cs, theme, searching: false)];
        }
        return [
          if (filtered.isNotEmpty) _playlistsGrid(filtered),
          if (_savedAlbums.isNotEmpty) ..._albumsSection(l10n, theme),
        ];
      case _LibraryTab.playlists:
        return filtered.isEmpty
            ? [_emptySliver(cs, theme, searching: false)]
            : [_playlistsGrid(filtered)];
      case _LibraryTab.albums:
        return _savedAlbums.isEmpty
            ? [
                _emptySliver(
                  cs,
                  theme,
                  searching: false,
                  icon: Icons.album_rounded,
                  text: l10n.savedAlbumsTitle,
                ),
              ]
            : [_albumsGrid()];
      case _LibraryTab.songs:
        return _songs.isEmpty
            ? [
                _emptySliver(
                  cs,
                  theme,
                  searching: false,
                  icon: Icons.music_note_rounded,
                  text: l10n.noPlaylists,
                ),
              ]
            : [_songsList()];
    }
  }

  Widget _playlistsGrid(List<Playlist> filtered) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          // 2 columnas: tarjetas grandes y simétricas que cubren el ancho.
          // Portada 1:1 + bloque de texto debajo.
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent:
              (MediaQuery.sizeOf(context).width - 12 * 2 - 12) / 2 + 48,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _PlaylistGridCard(
            playlist: filtered[i],
            trackCount: _counts[filtered[i].id] ?? 0,
            isCurrent: filtered[i].id == _activePlaylistId,
            isPlaying: _playing,
            onTap: () => widget.onSelectPlaylist(filtered[i]),
          ),
          childCount: filtered.length,
        ),
      ),
    );
  }

  /// Título "Albums guardados" + su grid (mismo lenguaje que las playlists).
  List<Widget> _albumsSection(AppLocalizations l10n, ThemeData theme) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.savedAlbumsTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      _albumsGrid(),
    ];
  }

  Widget _albumsGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent:
              (MediaQuery.sizeOf(context).width - 12 * 2 - 12) / 2 + 48,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _SavedAlbumCard(
            album: _savedAlbums[i],
            onTap: () => widget.onOpenAlbum?.call(_savedAlbums[i]),
          ),
          childCount: _savedAlbums.length,
        ),
      ),
    );
  }

  Widget _songsList() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverList.builder(
        itemCount: _songs.length,
        itemBuilder: (context, i) => TrackTile(
          track: _songs[i],
          isCurrent: _songs[i].id == _activeTrackId,
          isPlaying: _playing,
          onPlay: () => unawaited(playQueue(context, _songs, startIndex: i)),
        ),
      ),
    );
  }

  Widget _emptySliver(
    ColorScheme cs,
    ThemeData theme, {
    required bool searching,
    IconData? icon,
    String? text,
  }) {
    final l10n = AppLocalizations.of(context);
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching
                  ? Icons.search_off_rounded
                  : (icon ?? Icons.library_music_rounded),
              size: 64,
              color: cs.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              searching ? l10n.noMatchingPlaylists : (text ?? l10n.noPlaylists),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    final l10n = AppLocalizations.of(context);
    final tabs = <(_LibraryTab, String)>[
      (_LibraryTab.all, l10n.searchFilterAll),
      (_LibraryTab.playlists, l10n.playlistsTitle),
      (_LibraryTab.albums, l10n.libraryTabAlbums),
      (_LibraryTab.songs, l10n.libraryTabSongs),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (tab, label) in tabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _LibraryTabChip(
                label: label,
                active: tab == _tab,
                onTap: () => setState(() => _tab = tab),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pill de tab de la biblioteca móvil (Todos / Playlists / Álbumes / Canciones).
class _LibraryTabChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _LibraryTabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.22)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _PlaylistGridCard extends StatelessWidget {
  final Playlist playlist;
  final int trackCount;

  /// La playlist está en reproducción: muestra el indicador con su acento.
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;

  const _PlaylistGridCard({
    required this.playlist,
    required this.trackCount,
    required this.isCurrent,
    required this.isPlaying,
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
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
                // Indicador "now playing" en el acento de la playlist.
                if (isCurrent)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: NowPlayingBars(
                      active: isPlaying,
                      size: 12,
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

/// Card de álbum guardado: mismo lenguaje que [_PlaylistGridCard] (portada
/// 1:1 + textos debajo). Sin indicador de reproducción: el álbum abre el
/// screen del artista, no es una cola activa del shell.
class _SavedAlbumCard extends StatelessWidget {
  final YtmAlbum album;
  final VoidCallback? onTap;

  const _SavedAlbumCard({required this.album, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CoverImage(
                source: album.thumbnailUrl,
                cacheWidth: 200,
                fallback: Container(
                  color: cs.surfaceContainerHigh,
                  child: Icon(
                    Icons.album_rounded,
                    size: 28,
                    color: cs.primary.withValues(alpha: 0.45),
                  ),
                ),
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
              color: cs.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
