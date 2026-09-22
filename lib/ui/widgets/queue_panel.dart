import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart'
    show SearchService, YtmArtist, YtmArtistDetail, YtmTrackCredits;
import '../playlist_actions.dart';
import '../theme_controller.dart';
import 'cover_image.dart';
import 'track_tile.dart';

/// Fixed width of the open queue panel (same philosophy as the sidebar).
const double kQueuePanelWidth = 300;

/// Queue panel resize limits (desktop drag on the inner edge).
const double kQueueMinWidth = 240;
const double kQueueMaxWidth = 520;

/// Vertical margin of the panel (the same 12 used by sidebar and player).
const double _kQueueMargin = 12;

/// Playback queue panel: a floating glass container (same recipe as the sidebar: blur, translucent dark gradient and shadow) that SLIDES from the right edge, pushing the main container (the content and player shift left; closing them returns them).
class QueuePanel extends StatelessWidget {
  /// `true` = cola visible (el panel ocupa su ancho); `false` = colapsado.
  final bool open;

  /// Current width (owned by AppShell so it persists); `null` = default.
  final double? width;

  /// Dragging the inner (left) edge reports the new width live.
  final ValueChanged<double>? onWidthDrag;

  /// Drag finished → persist the width once.
  final VoidCallback? onWidthDragEnd;

  /// Opens the artist channel from the now-playing summary.
  final ValueChanged<YtmArtist>? onOpenArtist;

  const QueuePanel({
    super.key,
    required this.open,
    this.width,
    this.onWidthDrag,
    this.onWidthDragEnd,
    this.onOpenArtist,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final player = context.read<PlayerService>();
    final maxW = width ?? kQueuePanelWidth;

    return TweenAnimationBuilder<double>(
      // Animates the OPEN FRACTION (0→1), not the width: width changes from
      // the resize drag apply instantly while open/close keeps its tween.
      tween: Tween(begin: 0, end: open ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        final w = t * maxW;
        final right = t * (maxW / kQueuePanelWidth * _kQueueMargin);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: w,
              margin: EdgeInsets.fromLTRB(0, _kQueueMargin, right, _kQueueMargin),
              child: ClipRect(child: child),
            ),
            // Inner-edge resize handle: sits just left of the open panel,
            // full height of the glass area.
            if (open)
              Positioned(
                top: _kQueueMargin,
                bottom: _kQueueMargin,
                left: 0,
                width: 8,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      final next = (maxW - d.delta.dx)
                          .clamp(kQueueMinWidth, kQueueMaxWidth);
                      onWidthDrag?.call(next);
                    },
                    onHorizontalDragEnd: (_) => onWidthDragEnd?.call(),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        );
      },
      child: _QueueGlass(
        player: player,
        theme: theme,
        l10n: l10n,
        onOpenArtist: onOpenArtist,
      ),
    );
  }
}

/// Contenedor arrastrable de la cola en Android (NO es un screen): se muestra
/// como bottom sheet con asa, se puede deslizar hacia abajo para cerrarlo.
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final player = context.read<PlayerService>();

    // Fondo SÓLIDO con el mismo tono que los botones del player móvil:
    // overlay blanco/negro al 10% compuesto sobre el color real del player
    // (acento del artwork, o surfaceContainerHigh en idle).
    final accent = context.read<ThemeController>().accentColor;
    final darkContent = accent != null && accent.computeLuminance() > 0.55;
    final overlayBase = darkContent ? Colors.black : Colors.white;
    final playerBase =
        accent ?? theme.colorScheme.surfaceContainerHigh;
    final bg = Color.alphaBlend(
      overlayBase.withValues(alpha: 0.10),
      playerBase,
    );

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: Material(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Asa de arrastre.
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: SizedBox(
                  width: 36,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: darkContent
                          ? Colors.black.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.6),
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: _QueueBody(player: player, theme: theme, l10n: l10n),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Contenido del panel de la cola (desktop) con su cristal.
class _QueueGlass extends StatelessWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;

  /// Opens the artist channel from the now-playing summary.
  final ValueChanged<YtmArtist>? onOpenArtist;

  const _QueueGlass({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
          child: _QueuePanelTabs(
            player: player,
            theme: theme,
            l10n: l10n,
            onOpenArtist: onOpenArtist,
          ),
        ),
      ),
    );
  }
}

/// Lista de la cola (con su cabecera y el recuento). Compartida entre el
/// panel flotante (desktop) y el overlay a pantalla completa (móvil).
class _QueueBody extends StatelessWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;

  /// Switches the container to the now-playing panel.
  final VoidCallback? onToggleNowPlaying;

  const _QueueBody({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onToggleNowPlaying,
  });

  @override
  Widget build(BuildContext context) {
    final queueListenable = Listenable.merge([
      player.queue,
      player.queueIndex,
      player.shuffle,
    ]);

    return StreamBuilder<bool>(
      stream: player.playing,
      initialData: player.isPlaying,
      builder: (context, playingSnap) {
        final playing = playingSnap.data ?? false;
        return AnimatedBuilder(
          animation: queueListenable,
          builder: (context, _) {
            final queue = player.queue.value;
            final index = player.queueIndex.value;
            return Material(
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cabecera: título + nº de canciones + toggle.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
                    child: Row(
                      children: [
                              Icon(
                                Icons.queue_music_rounded,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.queueTitle,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                l10n.songCount(queue.length),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (onToggleNowPlaying != null) ...[
                                const SizedBox(width: 4),
                                SizedBox(
                                  height: 28,
                                  width: 28,
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    iconSize: 18,
                                    tooltip: l10n.nowPlayingLabel,
                                    onPressed: onToggleNowPlaying,
                                    icon: const Icon(
                                      Icons.album_rounded,
                                    ),
                                    color: theme
                                        .colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: queue.isEmpty
                              ? _EmptyQueue(theme: theme, l10n: l10n)
                              : ReorderableListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    0,
                                    10,
                                    12,
                                  ),
                                  buildDefaultDragHandles: false,
                                  proxyDecorator:
                                      (child, index, animation) =>
                                          AnimatedBuilder(
                                            animation: animation,
                                            builder: (_, child) =>
                                                Transform.scale(
                                                  scale:
                                                      1 +
                                                      animation.value * 0.02,
                                                  child: child,
                                                ),
                                            child: child,
                                          ),
                                  itemCount: queue.length,
                                  onReorderItem: (oldIndex, newIndex) {
                                    player.reorderQueue(oldIndex, newIndex);
                                  },
                                  itemBuilder: (context, i) {
                                    final track = queue[i];
                                    final isCurrent = i == index;
                                    return _QueueTrackRow(
                                      key: ValueKey('${track.id}_$i'),
                                      index: i,
                                      isCurrent: isCurrent,
                                      isPlaying: playing && isCurrent,
                                      track: track,
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
      );
  }
}

/// Estado vacío: aún no hay nada en la cola.
class _EmptyQueue extends StatelessWidget {
  final ThemeData theme;
  final AppLocalizations l10n;

  const _EmptyQueue({required this.theme, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 40,
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.queueEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.queueEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fila reordenable de la cola: mismo patrón que _SortableTrackRow del
/// playlist detail. Envuelve la TrackTile y añade un grip de arrastre con
/// ReorderableDragStartListener visible al hover.
class _QueueTrackRow extends StatefulWidget {
  final int index;
  final Track track;
  final bool isCurrent;
  final bool isPlaying;

  const _QueueTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
  });

  @override
  State<_QueueTrackRow> createState() => _QueueTrackRowState();
}

class _QueueTrackRowState extends State<_QueueTrackRow> {
  bool _hovered = false;

  /// Acento del artwork de esta pista, resuelto en initState (caché síncrona)
  /// o tras extraer el trío (async). `null` = la fila usa los colores del tema.
  Color? _accent;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveAccent());
  }

  Future<void> _resolveAccent() async {
    final url = widget.track.thumbnailUrl;
    if (url == null || url.isEmpty) return;
    final store = context.read<PaletteCacheStore>();
    final cached = store.get(url);
    if (cached != null) {
      _accent = cached;
      return;
    }
    if (store.isFailed(url)) return;
    try {
      final artworkCache = context.read<ArtworkCacheService>();
      final trio = await ArtworkPaletteService.trioFor(
        url,
        store,
        artworkCache: artworkCache,
      );
      final accent =
          trio.isEmpty
              ? null
              : (ArtworkPaletteService.accentFromTrio(trio) ?? trio.first);
      if (accent != null && mounted) {
        setState(() => _accent = accent);
      }
    } catch (_) {
      // Sin acento: la fila se queda con los colores estándar del tema.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final accent = _accent;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: TrackTile(
                track: widget.track,
                isCurrent: widget.isCurrent,
                isPlaying: widget.isPlaying,
                onPlay: () => player.playQueueAt(widget.index),
                showDuration: false,
                accentColor: accent,
              ),
            ),
            ReorderableDragStartListener(
              index: widget.index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color:
                      (_hovered ? (accent ?? theme.colorScheme.primary) : theme
                              .colorScheme
                              .outlineVariant)
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


/// Host for the two right-edge containers: the now-playing panel and the
/// queue list. Only ONE is visible at a time; the header button toggles
/// between them. Both stay mounted (space reserved, no layout jumps).
class _QueuePanelTabs extends StatefulWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;
  final ValueChanged<YtmArtist>? onOpenArtist;

  const _QueuePanelTabs({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
  });

  @override
  State<_QueuePanelTabs> createState() => _QueuePanelTabsState();
}

class _QueuePanelTabsState extends State<_QueuePanelTabs> {
  bool _showNowPlaying = true;

  @override
  Widget build(BuildContext context) {
    // Each panel fills the WHOLE glass: only the active one is laid out
    // (offstage keeps the queue's scroll state alive without taking space).
    return Stack(
      children: [
        Offstage(
          offstage: _showNowPlaying,
          child: _QueueBody(
            player: widget.player,
            theme: widget.theme,
            l10n: widget.l10n,
            onToggleNowPlaying: () => setState(() => _showNowPlaying = true),
          ),
        ),
        Offstage(
          offstage: !_showNowPlaying,
          child: _NowPlayingPanel(
            player: widget.player,
            theme: widget.theme,
            l10n: widget.l10n,
            onOpenArtist: widget.onOpenArtist,
            onToggleQueue: () => setState(() => _showNowPlaying = false),
          ),
        ),
      ],
    );
  }
}

/// Now-playing summary at the top of the desktop queue panel: source title,
/// artwork (1:1), track name, artist row with a favorite toggle, and a
/// clickable artist card (accent, avatar, name, monthly listeners).
class _NowPlayingPanel extends StatefulWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;
  final ValueChanged<YtmArtist>? onOpenArtist;

  /// Switches the shell container back to the queue panel.
  final VoidCallback? onToggleQueue;

  const _NowPlayingPanel({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
    this.onToggleQueue,
  });

  @override
  State<_NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<_NowPlayingPanel> {
  StreamSubscription<Track?>? _trackSub;
  Track? _track;
  bool _isFavorite = false;

  /// Artist card detail (listeners text). Resolved in background from the
  /// artist cache; `null` while loading or when the channel is unknown.
  YtmArtistDetail? _artistDetail;

  /// True while the channel is being resolved (background search fallback
  /// when the track has no channelId).
  bool _artistLoading = false;

  /// Track credits (WEB `next` description panel). Null while loading or
  /// when the track has none.
  YtmTrackCredits? _credits;

  @override
  void initState() {
    super.initState();
    _track = widget.player.currentTrackValue;
    _trackSub = widget.player.currentTrack.listen((t) {
      if (!mounted) return;
      setState(() {
        _track = t;
        _artistDetail = null;
        _artistLoading = false;
        _credits = null;
      });
      unawaited(_refreshFavorite());
      unawaited(_loadArtistDetail());
      unawaited(_loadCredits());
    });
    unawaited(_refreshFavorite());
    unawaited(_loadArtistDetail());
    unawaited(_loadCredits());
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshFavorite() async {
    final t = _track;
    if (t == null || !mounted) return;
    try {
      final fav = await isTrackFavorite(context, t);
      if (mounted && t.id == _track?.id) {
        setState(() => _isFavorite = fav);
      }
    } catch (_) {}
  }

  /// Resolves the artist detail in background with a STRICT 100% rule:
  /// 1) the track's own channelId when present; 2) otherwise the InnerTube
  /// `next` page for the track's videoId (the authoritative owner YouTube
  /// itself shows for that track — fresh data, no name guessing). Nothing
  /// else is accepted: without an exact source the card stays a skeleton.
  /// Late responses from a previous track never overwrite the current one.
  Future<void> _loadArtistDetail() async {
    final t = _track;
    if (t == null || !mounted) return;
    var channelId = t.artistChannelId;
    String? channelName;
    if (channelId == null || channelId.isEmpty) {
      final videoId = t.id.trim();
      if (videoId.isEmpty) return;
      if (mounted) setState(() => _artistLoading = true);
      try {
        final owner = await context
            .read<SearchService>()
            .fetchTrackChannel(videoId);
        if (!mounted) return;
        if (owner == null) {
          setState(() => _artistLoading = false);
          return;
        }
        channelId = owner.$1;
        channelName = owner.$2;
        setState(() {
          _fallbackChannelId = channelId;
          _artistDetail = YtmArtistDetail(
            browseId: channelId!,
            name: channelName?.isNotEmpty == true ? channelName! : t.artist,
            tracks: const [],
            albums: const [],
          );
        });
      } catch (_) {
        if (mounted) setState(() => _artistLoading = false);
        return;
      }
    }
    if (channelId.isEmpty || !mounted) {
      if (mounted) setState(() => _artistLoading = false);
      return;
    }
    try {
      final detail = await context.read<SearchService>().fetchArtistDetail(
        channelId,
        name: channelName?.isNotEmpty == true ? channelName : t.artist,
      );
      if (mounted && channelId == _resolvedChannelId) {
        setState(() {
          _artistDetail = detail ?? _artistDetail;
          _artistLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _artistLoading = false);
    }
  }

  /// Channel id the current resolution pass started for (guards late
  /// responses from overwriting a newer track's card).
  String? get _resolvedChannelId {
    final id = _track?.artistChannelId;
    if (id != null && id.isNotEmpty) return id;
    return _fallbackChannelId;
  }

  String? _fallbackChannelId;

  /// Loads the credits for the CURRENT track via the resolver (official
  /// "Song credits" dialog, then auto-generated description, then InnerTube
  /// search fallback for cached tracks without credits). Late responses from
  /// a previous track are discarded (guard by videoId). Silent failure:
  /// without credits nothing renders.
  Future<void> _loadCredits() async {
    final t = _track;
    final videoId = t?.id.trim() ?? '';
    if (t == null || videoId.isEmpty || !mounted) return;
    try {
      final credits = await context
          .read<SearchService>()
          .resolveTrackCredits(videoId, t.title, t.artist);
      if (!mounted || _track?.id.trim() != videoId) return;
      setState(() => _credits = credits);
    } catch (_) {
      if (mounted && _track?.id.trim() == videoId) {
        setState(() => _credits = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final l10n = widget.l10n;
    final track = _track;

    // Header row: label + panel switch button. Same style as the queue
    // header (titleMedium w700, icon in primary, same paddings).
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
      child: Row(
        children: [
          Icon(
            Icons.album_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.nowPlayingLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            height: 28,
            width: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              tooltip: l10n.queueTitle,
              onPressed: widget.onToggleQueue,
              icon: const Icon(Icons.queue_music_rounded),
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );

    Widget body;
    if (track == null) {
      body = _NowPlayingSkeleton(theme: theme, message: l10n.queueEmpty);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Artwork 1:1 with the same rounded corners (space always
          // reserved: the aspect-ratio box never collapses).
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1,
              child: CoverImage(
                source: track.thumbnailUrl,
                fallback: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  child: Icon(
                    Icons.music_note_rounded,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            track.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                height: 30,
                width: 30,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: () async {
                    await toggleTrackFavorite(
                      context,
                      track,
                      current: _isFavorite,
                    );
                    if (mounted) unawaited(_refreshFavorite());
                  },
                  icon: Icon(
                    _isFavorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: _isFavorite
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ArtistInfoCard(
            track: track,
            detail: _artistDetail,
            loading: _artistLoading,
            theme: theme,
            l10n: l10n,
            onOpen: _artistDetail == null
                ? null
                : () => widget.onOpenArtist?.call(
                    YtmArtist(
                      browseId: _artistDetail!.browseId,
                      name: _artistDetail!.name,
                      thumbnailUrl: _artistDetail!.thumbnailUrl,
                      subscriberCount: _artistDetail!.subscriberCount,
                    ),
                  ),
          ),
          if (_credits != null) ...[
            const SizedBox(height: 14),
            _CreditsCard(
              credits: _credits!,
              theme: theme,
              l10n: l10n,
              artworkUrl: track.thumbnailUrl,
            ),
          ],
        ],
      );
    }

    // Header with the EXACT same insets as the queue header: the outer
    // padding applies to the BODY only, so icon/title/switch sit at the
    // same distance from the glass edge as in the queue panel.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          // Fill the panel height even when the content is shorter, so
          // the background glass reaches the bottom edge.
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: KeyedSubtree(
                    key: ValueKey(track?.id ?? 'empty'),
                    child: body,
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

/// Default skeletons for the now-playing panel: fixed-size placeholders so
/// the panel never jumps while the track / artist card resolve.
class _NowPlayingSkeleton extends StatelessWidget {
  final ThemeData theme;
  final String? message;

  const _NowPlayingSkeleton({required this.theme, this.message});

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.12);
    Widget block(double w, double h, {double r = 8}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(r),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Artwork placeholder (full width, square): reserves the space.
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 10),
        block(double.infinity, 18),
        const SizedBox(height: 6),
        block(120, 12),
        const SizedBox(height: 10),
        // Artist card placeholder.
        Container(
          height: 60,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 10),
          Text(
            message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Credits card below the artist card: SAME recipe as `_ArtistInfoCard`
/// (accent tint from the track artwork over the panel surface, radius 16,
/// same paddings). Header + one pill per credit row, 2 per line.
class _CreditsCard extends StatelessWidget {
  final YtmTrackCredits credits;
  final ThemeData theme;
  final AppLocalizations l10n;

  /// Current track artwork: source of the card's accent tint.
  final String? artworkUrl;

  const _CreditsCard({
    required this.credits,
    required this.theme,
    required this.l10n,
    this.artworkUrl,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _resolveAccent(context);
    final bg = accent == null
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
        : Color.alphaBlend(
            accent.withValues(alpha: 0.16),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          );

    // One bullet row: 4px dot + text (wraps inside the row).
    Widget bullet(String text, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: icon != null
                    ? Icon(
                        icon,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 6, right: 5),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
              if (icon != null) const SizedBox(width: 7),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.35,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.creditsLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          for (final s in credits.sections) ...[
            // Section header: the credit role ("Performed by").
            Text(
              s.role,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final name in s.names) bullet(name),
            const SizedBox(height: 8),
          ],
          if (credits.album != null)
            bullet(credits.album!, icon: Icons.album_rounded),
          if (credits.distributor != null)
            bullet(credits.distributor!, icon: Icons.local_shipping_rounded),
        ],
      ),
    );
  }

  /// Accent from the track artwork (palette cache, sync read).
  Color? _resolveAccent(BuildContext context) {
    final url = artworkUrl;
    if (url == null || url.isEmpty) return null;
    final trio = context.read<PaletteCacheStore>().getTrio(url);
    if (trio == null) return null;
    return ArtworkPaletteService.accentFromTrio(trio);
  }
}

/// Clickable artist card: accent tint from the artist avatar, avatar, name,
/// monthly listeners ("218M monthly audience") when already resolved.
class _ArtistInfoCard extends StatelessWidget {
  final Track track;
  final YtmArtistDetail? detail;

  /// True while the channel is being resolved in background.
  final bool loading;
  final ThemeData theme;
  final AppLocalizations l10n;
  final VoidCallback? onOpen;

  const _ArtistInfoCard({
    required this.track,
    required this.detail,
    this.loading = false,
    required this.theme,
    required this.l10n,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _resolveAccent(context);
    final bg = accent == null
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
        : Color.alphaBlend(accent.withValues(alpha: 0.16),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35));
    final avatarSide = 72.0;
    final skeleton = detail == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: skeleton ? null : onOpen,
        borderRadius: BorderRadius.circular(16),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: bg,
          ),
          child: Column(
            children: [
              // Big avatar on top.
              ClipOval(
                child: SizedBox(
                  width: avatarSide,
                  height: avatarSide,
                  child: skeleton
                      ? ColoredBox(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.12),
                        )
                      : CoverImage(
                          source: detail?.thumbnailUrl,
                          fallback: ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.person_rounded,
                              size: 34,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              // Name below the avatar.
              if (skeleton)
                Container(
                  width: 120,
                  height: 12,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                )
              else
                Text(
                  detail!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(height: 3),
              // Monthly listeners below the name.
              if (skeleton)
                Container(
                  width: 84,
                  height: 10,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(5),
                  ),
                )
              else
                Text(
                  detail!.audienceText ?? l10n.aboutArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Accent from the artist avatar (palette cache, sync read only: no
  /// extraction here to keep the card cheap).
  Color? _resolveAccent(BuildContext context) {
    final url = detail?.thumbnailUrl;
    if (url == null || url.isEmpty) return null;
    final trio = context.read<PaletteCacheStore>().getTrio(url);
    if (trio == null) return null;
    return ArtworkPaletteService.accentFromTrio(trio);
  }
}
