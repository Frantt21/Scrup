import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/player_service.dart';
import '../playback.dart';
import '../theme_controller.dart';
import '../playlist_actions.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/cover_image.dart';
import '../widgets/edit_metadata_dialog.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
import '../widgets/scrup_toasts.dart';
import '../widgets/track_tile.dart';

/// Floating glass container showing playlist detail with hero, tracks,
/// drag reorder, context menus and ambient color from cover art.
class PlaylistDetailView extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onBack;
  final ValueChanged<Playlist>? onUpdated;

  const PlaylistDetailView({
    super.key,
    required this.playlist,
    required this.onBack,
    this.onUpdated,
  });

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  static const double _heroControlHeight = 44.0;
  late final Stream<List<Track>> _tracksStream;
  late final Stream<Playlist?> _playlistStream;
  StreamSubscription<List<Track>>? _tracksSub;
  StreamSubscription<Playlist?>? _playlistSub;
  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _nullTrackTimer;
  List<Track> _tracks = const [];

  Track? _currentTrack;
  bool _playing = false;

  int? _activePlaylistId;
  late final PlayerService _player;

  Playlist? _playlist;

  late final PaletteCacheStore _store;

  Color? _ambientColor;
  String? _ambientFor;
  int _ambientToken = 0;

  static final Map<String, Color?> _paletteCache = {};

  static final Map<String, Color?> _trackPaletteCache = {};

  static final Set<String> _pendingTrackColors = {};

  bool _coverHovered = false;

  bool _filterOpen = false;
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDatabase>();
    _playlist = widget.playlist;
    _playlistStream = db.watchPlaylist(widget.playlist.id);
    _playlistSub = _playlistStream.listen((p) {
      if (!mounted) return;
      setState(() {
        if (p != null) _playlist = p;
      });
      if (p != null) _maybeExtractAmbient(p.coverUrl);
    });
    _tracksStream = db.watchPlaylistTracks(widget.playlist.id);
    _tracksSub = _tracksStream.listen((tracks) {
      if (!mounted) return;
      setState(() => _tracks = tracks);
    });
    _store = context.read<PaletteCacheStore>();
    _player = context.read<PlayerService>();
    _currentTrack = _player.currentTrackValue;
    _playing = _player.isPlaying;
    _activePlaylistId = _player.activePlaylistId.value;
    _player.activePlaylistId.addListener(_onActivePlaylistChanged);
    _trackSub = _player.currentTrack.listen((t) {
      if (!mounted) return;
      if (t == null) {
        _nullTrackTimer?.cancel();
        _nullTrackTimer = Timer(const Duration(milliseconds: 80), () {
          if (mounted) setState(() => _currentTrack = null);
        });
        return;
      }
      _nullTrackTimer?.cancel();
      setState(() => _currentTrack = t);
    });
    _playingSub = _player.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
    _maybeExtractAmbient(widget.playlist.coverUrl);
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    _playlistSub?.cancel();
    _trackSub?.cancel();
    _playingSub?.cancel();
    _nullTrackTimer?.cancel();
    _player.activePlaylistId.removeListener(_onActivePlaylistChanged);
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _onActivePlaylistChanged() {
    if (!mounted) return;
    setState(() => _activePlaylistId = _player.activePlaylistId.value);
  }

  Color? _trackColorFor(Track track) {
    final url = track.thumbnailUrl;
    if (url == null) return null;
    if (_trackPaletteCache.containsKey(url)) return _trackPaletteCache[url];
    final stored = _store.get(url);
    if (stored != null) {
      _trackPaletteCache[url] = stored;
      return stored;
    }
    if (_store.isFailed(url)) {
      _trackPaletteCache[url] = null;
      return null;
    }
    if (_pendingTrackColors.add(url)) {
      unawaited(_loadTrackColor(url));
    }
    return null;
  }

  Future<void> _loadTrackColor(String url) async {
    Color? color;
    try {
      final artworkCache = context.read<ArtworkCacheService>();
      final trio = await ArtworkPaletteService.trioFor(
        url,
        _store,
        artworkCache: artworkCache,
      );
      if (trio.isNotEmpty) {
        color = ArtworkPaletteService.accentFromTrio(trio) ?? trio.first;
      } else {
        color = _store.get(url);
      }
    } catch (_) {
      color = null;
    }
    _pendingTrackColors.remove(url);
    _trackPaletteCache[url] = color;
    if (mounted) setState(() {});
  }

  void _maybeExtractAmbient(String? coverUrl) {
    if (coverUrl == null || coverUrl == _ambientFor) return;
    _ambientFor = coverUrl;
    if (_paletteCache.containsKey(coverUrl)) {
      setState(() => _ambientColor = _paletteCache[coverUrl]);
      return;
    }
    final stored = _store.get(coverUrl);
    if (stored != null) {
      _paletteCache[coverUrl] = stored;
      setState(() => _ambientColor = stored);
      return;
    }
    if (_store.isFailed(coverUrl)) {
      _paletteCache[coverUrl] = null;
      setState(() => _ambientColor = null);
      return;
    }
    if (_ambientColor != null) {
      setState(() => _ambientColor = null);
    }
    final token = ++_ambientToken;
    unawaited(_extractAmbient(coverUrl, token));
  }

  Future<void> _extractAmbient(String source, int token) async {
    Color? color;
    try {
      final artworkCache = context.read<ArtworkCacheService>();
      final trio = await ArtworkPaletteService.trioFor(
        source,
        _store,
        artworkCache: artworkCache,
      );
      if (trio.isNotEmpty) {
        color = ArtworkPaletteService.accentFromTrio(trio) ?? trio.first;
      } else {
        color = _store.get(source);
      }
    } catch (_) {
      color = null;
    }
    _paletteCache[source] = color;
    if (!mounted || token != _ambientToken) return;
    setState(() => _ambientColor = color);
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    await playQueue(context, _tracks, playlistId: widget.playlist.id);
  }

  bool get _isPlayingThisPlaylist =>
      _activePlaylistId != null && _activePlaylistId == widget.playlist.id;

  Future<void> _playShuffled() async {
    if (_tracks.isEmpty) return;
    final player = context.read<PlayerService>();
    if (!player.shuffle.value) player.toggleShuffle();
    await playQueue(context, _tracks, playlistId: widget.playlist.id);
  }

  bool get _filterActive => _filterCtrl.text.trim().isNotEmpty;

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

  List<Track> get _visibleTracks {
    final q = _normQuery(_filterCtrl.text.trim());
    if (q.isEmpty) return _tracks;
    return [
      for (final t in _tracks)
        if (_normQuery(t.title).contains(q) || _normQuery(t.artist).contains(q))
          t,
    ];
  }

  void _openFilter() {
    setState(() => _filterOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  void _closeFilter() {
    _filterFocus.unfocus();
    _filterCtrl.clear();
    setState(() => _filterOpen = false);
  }

  Future<void> _removeTrack(Track track) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.confirmRemoveTrackTitle),
        content: Text(l10n.confirmRemoveTrackBody(track.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.removeFromPlaylist),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppDatabase>().removeFromPlaylist(
      widget.playlist.id,
      track.id,
    );
  }

  Future<void> _onReorderItem(int oldIndex, int newIndex) async {
    final updated = [..._tracks];
    final moved = updated.removeAt(oldIndex);
    updated.insert(newIndex, moved);
    setState(() => _tracks = updated);
    try {
      await context.read<AppDatabase>().reorderPlaylistTracks(
        widget.playlist.id,
        [for (final t in updated) t.id],
      );
  } catch (_) {}
  }

  Future<void> _showTrackMenu(Track track, Offset position) async {
    final l10n = AppLocalizations.of(context);
    final action = await showMenu<String>(
      context: context,
      // Anclaje en la posición del cursor.
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
          color: _menuTrackColor(track) ?? _ambientColor,
        ),
        ContextMenuItem(
          value: 'add',
          icon: Icons.playlist_add_rounded,
          label: l10n.addToPlaylist,
          color: _menuTrackColor(track) ?? _ambientColor,
        ),
        ContextMenuItem(
          value: 'edit',
          icon: Icons.edit_rounded,
          label: l10n.editMetadata,
          color: _menuTrackColor(track) ?? _ambientColor,
        ),
        ContextMenuItem(
          value: 'remove',
          icon: Icons.remove_circle_rounded,
          label: l10n.removeFromPlaylist,
          color: _menuTrackColor(track) ?? _ambientColor,
        ),
        ContextMenuItem(
          value: 'recalc',
          icon: Icons.palette_rounded,
          label: l10n.recalcColors,
          color: _menuTrackColor(track) ?? _ambientColor,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'play':
        final start = _tracks.indexWhere((t) => t.id == track.id);
        await playQueue(
          context,
          _tracks,
          startIndex: start < 0 ? 0 : start,
          playlistId: widget.playlist.id,
        );
      case 'add':
        await showAddToPlaylistDialog(context, track);
      case 'edit':
        await _editTrackMetadata(track);
      case 'remove':
        await _removeTrack(track);
      case 'recalc':
        await _recalcTrackColors(track);
    }
  }

  Future<void> _editTrackMetadata(Track track) async {
    final saved = await showDialog<Track>(
      context: context,
      builder: (ctx) => EditMetadataDialog(track: track),
    );
    if (saved == null || !mounted) return;
    final player = context.read<PlayerService>();
    if (player.currentTrackValue?.id == track.id) {
      await player.updateCurrentMetadata(saved);
    } else {
      await context.read<AppDatabase>().updateTrackMetadata(saved);
    }
    if (!mounted) return;
    showScrupToast(
      AppLocalizations.of(context).metadataSaved,
      kind: ScrupToastKind.success,
    );
  }

  Color? _menuTrackColor(Track track) {
    final url = track.thumbnailUrl;
    if (url == null) return null;
    final cached = _trackPaletteCache[url];
    if (cached != null) return cached;
    final stored = _store.get(url);
    if (stored != null) _trackPaletteCache[url] = stored;
    return stored;
  }

  // ------------------------------------------------------------ edición

  Future<void> _editPlaylist() async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final playlist = _playlist ?? widget.playlist;
    final result =
        await showDialog<
          ({
            String name,
            String? description,
            String? coverToCopy,
            String? coverUrl,
            bool removeCover,
          })
        >(
          context: context,
          builder: (_) =>
              _EditPlaylistDialog(playlist: playlist, tracks: _tracks),
        );
    if (result == null || !mounted) return;

    try {
      final name = result.name.trim();
      if (name.isNotEmpty && name != playlist.name) {
        await db.renamePlaylist(playlist.id, name);
      }
      await db.setPlaylistDescription(playlist.id, result.description);

      final currentCover = (await db.getPlaylist(playlist.id))?.coverUrl;
      String? newCover = currentCover;
      if (result.removeCover) {
        newCover = null;
      } else if (result.coverToCopy != null) {
        newCover = await copyPlaylistCoverToAppDir(
          playlist.id,
          result.coverToCopy!,
        );
      } else if (result.coverUrl != null) {
        newCover = result.coverUrl;
      }
      final coverChanged =
          result.removeCover ||
          result.coverToCopy != null ||
          result.coverUrl != null;
      if (coverChanged && newCover != currentCover) {
        await db.setPlaylistCover(playlist.id, newCover);
        // Limpiar la portada local anterior (no deja huérfanos).
        if (currentCover != null &&
            CoverImage.isLocalPath(currentCover) &&
            newCover != currentCover) {
          final old = File(currentCover);
          if (await old.exists()) await old.delete();
        }
      }

      if (!mounted) return;
      showScrupToast(l10n.playlistUpdated, kind: ScrupToastKind.success);
      final updated = await db.getPlaylist(playlist.id);
      if (mounted && updated != null) {
        widget.onUpdated?.call(updated);
      }
    } catch (_) {
      if (!mounted) return;
      showScrupToast(l10n.cantSaveChanges, kind: ScrupToastKind.error);
    }
  }

  String _fmtDuration(Duration d, AppLocalizations l10n) {
    final m = d.inMinutes;
    if (m < 1) return l10n.lessThanOneMinute;
    if (m < 60) return l10n.durationMinutes(m);
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? l10n.durationHours(h) : l10n.durationHoursMinutes(h, rem);
  }

  String get _countAndDuration {
    final l10n = AppLocalizations.of(context);
    final count = _tracks.length;
    final total = _tracks.fold(
      Duration.zero,
      (acc, t) => acc + (t.duration ?? Duration.zero),
    );
    return l10n.playlistMeta(l10n.songCount(count), _fmtDuration(total, l10n));
  }

  Widget _coverArt(ThemeData theme, String? url) {
    return CoverImage(
      source: url,
      cacheWidth: 400,
      fallback: Container(
        decoration: BoxDecoration(
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
          size: 40,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  // Mobile playlist detail: full-bleed cover header with dominant color bg.
  Widget _buildMobilePlaylistDetail(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l10n,
    Playlist playlist,
    int count,
    String? currentId,
  ) {
    final bgColor = _ambientColor ?? theme.colorScheme.surface;
    final coverUrl = playlist.coverUrl;

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // Full-width cover image header with gradient overlay
              SliverAppBar(
                expandedHeight: MediaQuery.of(context).size.width,
                pinned: false,
                floating: false,
                snap: false,
                stretch: true,
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  stretchModes: const [
                    StretchMode.zoomBackground,
                    StretchMode.blurBackground,
                  ],
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (coverUrl != null && coverUrl.isNotEmpty)
                        CoverImage(
                          source: coverUrl,
                          fit: BoxFit.cover,
                          fallback: Container(
                            color: bgColor,
                            child: const Center(
                              child: Icon(Icons.queue_music_rounded, size: 120),
                            ),
                          ),
                        )
                      else
                        Container(
                          color: bgColor,
                          child: const Center(
                            child: Icon(Icons.queue_music_rounded, size: 120),
                          ),
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              bgColor.withValues(alpha: 0.1),
                              bgColor.withValues(alpha: 0.6),
                              bgColor,
                            ],
                            stops: const [0.0, 0.6, 1.0],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Playlist info + action buttons
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Column(
                    children: [
                      Text(
                        playlist.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (playlist.description != null &&
                          playlist.description!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          playlist.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '$count tracks',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: count == 0 ? null : _playAll,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(l10n.play),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.tonalIcon(
                            onPressed: count == 0 ? null : _playShuffled,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                            ),
                            icon: const Icon(Icons.shuffle_rounded),
                            label: Text(l10n.shuffle),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Track list
              if (_tracks.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'No tracks',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 100),
                  sliver: SliverList.builder(
                    itemCount: _tracks.length,
                    itemBuilder: (context, i) {
                      final track = _tracks[i];
                      return TrackTile(
                        track: track,
                        onPlay: () {
                          final start = _tracks.indexWhere((t) => t.id == track.id);
                          playQueue(
                            context,
                            _tracks,
                            startIndex: start < 0 ? 0 : start,
                            playlistId: widget.playlist.id,
                          );
                        },
                        isCurrent: track.id == currentId,
                        isPlaying: _playing,
                        accentColor: _trackColorFor(track) ?? _ambientColor,
                      );
                    },
                  ),
                ),
            ],
          ),
          // Floating back button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.8),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, size: 20),
                        onPressed: widget.onBack,
                        padding: EdgeInsets.zero,
                      ),
                    ),

                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  ThemeData _themeWithPlaylistColor(ThemeData base, Color color) {
    final onPrimary =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: color,
        onPrimary: onPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final playlistColor = _ambientColor;
    final theme = playlistColor != null
        ? _themeWithPlaylistColor(baseTheme, playlistColor)
        : baseTheme;
    final playlist = _playlist ?? widget.playlist;
    final count = _tracks.length;
    final currentId = _currentTrack?.id;

    Widget rowFor(BuildContext context, int i) {
      final track = _visibleTracks[i];
      return _SortableTrackRow(
        key: ValueKey(track.id),
        index: i,
        accentColor: _trackColorFor(track) ?? playlistColor,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onSecondaryTapUp: (details) =>
                _showTrackMenu(track, details.globalPosition),
          child: TrackTile(
            track: track,
            onPlay: () {
              final start = _tracks.indexWhere((t) => t.id == track.id);
              playQueue(
                context,
                _tracks,
                startIndex: start < 0 ? 0 : start,
                playlistId: widget.playlist.id,
              );
            },
            isCurrent: track.id == currentId,
            isPlaying: _playing,
            accentColor: _trackColorFor(track) ?? playlistColor,
          ),
          ),
        ),
      );
    }

    // Mobile: full-bleed layout inspired by forawn_mobile.
    if (Binaries.isMobile) {
      return _buildMobilePlaylistDetail(context, theme, l10n, playlist, count, currentId);
    }

    return Theme(
      data: theme,
      child: Container(
        constraints: const BoxConstraints.expand(),
        margin: const EdgeInsets.fromLTRB(12, 12, 12, kPlayerClearance),
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
              color:
                  (playlistColor != null
                          ? Color.lerp(
                              theme.colorScheme.surfaceContainerHighest,
                              playlistColor,
                              0.30,
                            )!
                          : theme.colorScheme.surfaceContainerHighest)
                      .withValues(alpha: 0.72),
            ),                child: Material(
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 24, 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _heroCover(theme, playlist.coverUrl),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                playlist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.displaySmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  height: 1.05,
                                ),
                              ),
                              if (playlist.description != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  playlist.description!,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.9),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                          Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.icon(
                                    onPressed: count == 0 ? null : _playAll,
                                    style: FilledButton.styleFrom(
                                    minimumSize: const Size(
                                        0,
                                        _heroControlHeight,
                                      ),
                                    ),
                                    icon: const Icon(Icons.play_arrow_rounded),
                                    label: Text(l10n.play),
                                  ),
                                  FilledButton.icon(
                                    onPressed: count == 0
                                        ? null
                                        : _playShuffled,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor:
                                          theme.colorScheme.primary,
                                      minimumSize: const Size(
                                        0,
                                        _heroControlHeight,
                                      ),
                                    ),
                                    icon: const Icon(Icons.shuffle_rounded),
                                    label: Text(l10n.shuffle),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeOutCubic,
                                    width: _filterOpen
                                        ? 260
                                        : _heroControlHeight,
                                    height: _heroControlHeight,
                                    child: ClipRect(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        child: _filterOpen
                                            ? TextField(
                                                key: const ValueKey('field'),
                                                controller: _filterCtrl,
                                                focusNode: _filterFocus,
                                                onChanged: (_) =>
                                                    setState(() {}),
                                                style:
                                                    theme.textTheme.bodyMedium,
                                                decoration: InputDecoration(
                                                  hintText:
                                                      l10n.playlistFilterHint,
                                                  prefixIcon: const Icon(
                                                    Icons.search_rounded,
                                                    size: 18,
                                                  ),
                                                  prefixIconConstraints:
                                                      const BoxConstraints(
                                                        minWidth: 36,
                                                      ),
                                                  suffixIcon: IconButton(
                                                    onPressed: _closeFilter,
                                                    icon: const Icon(
                                                      Icons.close_rounded,
                                                      size: 18,
                                                    ),
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                  ),
                                                  isDense: true,
                                                  filled: true,
                                                  contentPadding:
                                                      EdgeInsets.zero,
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          20,
                                                        ),
                                                    borderSide: BorderSide.none,
                                                  ),
                                                ),
                                              )
                                            : IconButton(
                                                key: const ValueKey('icon'),
                                                onPressed: count == 0
                                                    ? null
                                                    : _openFilter,
                                                tooltip:
                                                    l10n.playlistFilterHint,
                                                icon: const Icon(
                                                  Icons.search_rounded,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _countAndDuration,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (_isPlayingThisPlaylist)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: NowPlayingBars(
                                        active: _playing,
                                        size: 14,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _tracks.isEmpty
                        ? Center(                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                Icon(
                                  Icons.music_off_rounded,
                                  size: 64,
                                  color:
                                      (playlistColor ??
                                              theme
                                                  .colorScheme
                                                  .onSurfaceVariant)
                                          .withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  l10n.emptyPlaylist,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.emptyPlaylistHint,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _visibleTracks.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search_off_rounded,
                                  size: 56,
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  l10n.playlistNoResults,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _filterActive
                        ? ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                            itemCount: _visibleTracks.length,
                            itemBuilder: rowFor,
                          )
                        : ReorderableListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                            buildDefaultDragHandles: false,
                            proxyDecorator: (child, index, animation) =>
                                AnimatedBuilder(
                                  animation: animation,
                                  builder: (_, child) => Transform.scale(
                                    scale: 1 + animation.value * 0.02,
                                    child: child,
                                  ),
                                  child: child,
                                ),
                            itemCount: _tracks.length,
                            onReorderItem: _onReorderItem,
                            itemBuilder: rowFor,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _recalcTrackColors(Track track) async {
    final url = track.thumbnailUrl;
    if (url == null || url.isEmpty) return;
    final store = context.read<PaletteCacheStore>();
    await ArtworkPaletteService.trioFor(
      url,
      store,
      force: true,
      artworkCache: context.read<ArtworkCacheService>(),
    );
    if (mounted) {
      _trackPaletteCache.remove(url);
      context.read<ThemeController>().invalidateColor(url);
      // Re-aplicar el acento si es la pista actual.
      if (_currentTrack?.thumbnailUrl == url) {
        final newAccent = store.get(url);
        context.read<ThemeController>().setAccent(newAccent);
      }
      setState(() {});
      showScrupToast(
        AppLocalizations.of(context).colorsUpdated,
        kind: ScrupToastKind.success,
      );
    }
  }

  Widget _heroCover(ThemeData theme, String? coverUrl) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _coverHovered = true),
      onExit: (_) => setState(() => _coverHovered = false),
      child: GestureDetector(
        onTap: _editPlaylist,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              SizedBox(
                width: 160,
                height: 160,
                child: _coverArt(theme, coverUrl),
              ),
              // Overlay de edición (solo en hover)
              if (_coverHovered)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_rounded, size: 26),
                            color: Colors.white,
                            tooltip: AppLocalizations.of(context).editPlaylist,
                            onPressed: _editPlaylist,
                          ),
                          Text(
                            AppLocalizations.of(context).edit,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
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

/// Fila reordenable de la lista: envuelve la [TrackTile] (ya construida) y
/// añade a la derecha un grip de arrastre que se intensifica con el hover de
/// la fila. Solo el grip inicia el arrastre: el resto de la fila conserva el
/// clic para reproducir y el clic derecho para el menú, sin pelearse con el
/// scroll vertical.
class _SortableTrackRow extends StatefulWidget {
  final int index;

  /// Fila ya construida (GestureDetector + TrackTile).
  final Widget child;

  /// Color de acento (artwork/playlist) para el grip; null usa el primario.
  final Color? accentColor;

  const _SortableTrackRow({
    super.key,
    required this.index,
    required this.child,
    required this.accentColor,
  });

  @override
  State<_SortableTrackRow> createState() => _SortableTrackRowState();
}

class _SortableTrackRowState extends State<_SortableTrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        // Sustituye al separatorBuilder del ListView anterior.
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(child: widget.child),
            ReorderableDragStartListener(
              index: widget.index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color:
                      (_hovered
                              ? (widget.accentColor ??
                                    theme.colorScheme.primary)
                              : theme.colorScheme.outlineVariant)
                          .withValues(alpha: _hovered ? 0.85 : 0.45),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal para editar una playlist: nombre, descripción y portada (desde
/// archivo, desde una canción de la playlist, o quitarla).
class _EditPlaylistDialog extends StatefulWidget {
  final Playlist playlist;
  final List<Track> tracks;

  const _EditPlaylistDialog({required this.playlist, required this.tracks});

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  String? _imagePath;
  String? _trackCoverUrl;
  bool _removeCover = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.playlist.name);
    _descController = TextEditingController(
      text: widget.playlist.description ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final images = XTypeGroup(
      label: AppLocalizations.of(context).images,
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;
    setState(() {
      _imagePath = file.path;
      _trackCoverUrl = null;
      _removeCover = false;
    });
  }

  Future<void> _pickTrackCover() async {
    if (widget.tracks.isEmpty) return;
    final url = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                AppLocalizations.of(ctx).coverFromTrack,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final track in widget.tracks.take(12))
              ListTile(
                dense: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CoverImage(
                      source: track.thumbnailUrl,
                      fallback: _thumbnailFallback(ctx),
                    ),
                  ),
                ),
                title: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, track.thumbnailUrl),
              ),
          ],
        ),
      ),
    );
    if (url == null || !mounted) return;
    setState(() {
      _trackCoverUrl = url;
      _imagePath = null;
      _removeCover = false;
    });
  }

  Widget _thumbnailFallback(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note_rounded,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// Fuente que se mostrará en la vista previa (lo que quedará como portada).
  String? get _previewSource {
    if (_imagePath != null) return _imagePath;
    if (_trackCoverUrl != null) return _trackCoverUrl;
    if (_removeCover) return null;
    return widget.playlist.coverUrl;
  }

  String get _previewLabel {
    final l10n = AppLocalizations.of(context);
    if (_imagePath != null) return p.basename(_imagePath!);
    if (_trackCoverUrl != null) return l10n.coverFromTrackLabel;
    if (_removeCover) return l10n.noCover;
    return widget.playlist.coverUrl != null ? l10n.currentCover : l10n.noCover;
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final desc = _descController.text.trim();
    Navigator.pop(context, (
      name: name,
      description: desc.isEmpty ? null : desc,
      coverToCopy: _imagePath,
      coverUrl: _trackCoverUrl,
      removeCover: _removeCover,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // Mismo shell glass que el resto de diálogos de la app (editar
    // metadatos, sync de letra, búsqueda LRCLIB): Container sólido con
    // radio 18 + sombra profunda, cabecera con X y cuerpo en padding 24.
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          // Fondo sólido (sin borde ni gradiente translúcido).
          color: theme.colorScheme.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.editPlaylist,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.close,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(
                    l10n.playlistName,
                    _nameController,
                    Icons.queue_music_rounded,
                    submit: true,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l10n.description,
                    _descController,
                    Icons.notes_rounded,
                    maxLines: 3,
                    maxLength: 300,
                  ),
                  const SizedBox(height: 20),
                  // Portada: vista previa + origen (archivo / canción de la
                  // playlist) + quitar.
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CoverImage(
                            source: _previewSource,
                            cacheWidth: 120,
                            fallback: Container(
                              decoration: BoxDecoration(
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
                                size: 22,
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _previewLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.image_rounded, size: 20),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.chooseImage,
                        onPressed: _pickImage,
                      ),
                      IconButton(
                        icon: const Icon(Icons.library_music_rounded, size: 20),
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.coverFromTrackLabel,
                        onPressed: _pickTrackCover,
                      ),
                      if (_previewSource != null)
                        IconButton(
                          icon: const Icon(Icons.delete_rounded, size: 20),
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.removeCover,
                          onPressed: () => setState(() {
                            _imagePath = null;
                            _trackCoverUrl = null;
                            _removeCover = true;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _submit, child: Text(l10n.save)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Campo con su label como título ENCIMA del input (mismo patrón que el
  /// editor de metadatos). [submit] habilita Enter para guardar; en campos
  /// multilínea se omite el prefixIcon (queda mal centrado en 3 líneas).
  Widget _field(
    String label,
    TextEditingController controller,
    IconData icon, {
    int maxLines = 1,
    int? maxLength,
    bool submit = false,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          autofocus: controller == _nameController,
          maxLines: maxLines,
          maxLength: maxLength,
          decoration: InputDecoration(
            hintText: label,
            prefixIcon: maxLines == 1 ? Icon(icon, size: 18) : null,
            filled: true,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            counterText: '',
          ),
          style: theme.textTheme.bodyMedium,
          onSubmitted: submit ? (_) => _submit() : null,
        ),
      ],
    );
  }
}
