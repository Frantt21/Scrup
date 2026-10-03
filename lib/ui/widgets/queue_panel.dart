import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart'
    show SearchService, YtmArtist, YtmArtistDetail;
import '../playlist_actions.dart';
import '../theme_controller.dart';
import 'cover_image.dart';
import 'now_playing_cards.dart';
import 'track_tile.dart';

// Cards del now playing extraídas a [now_playing_cards.dart] para
// compartirlas con el player expandido de Android; reexportadas aquí para
// no tocar los imports de quienes ya consumían este archivo.
export 'now_playing_cards.dart'
    show
        ArtistInfoCard,
        CreditsCard,
        LyricsPreviewCard,
        NowPlayingExtras,
        kNowPlayingCardGap;

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

  /// Opens the lyrics container from the lyrics preview card.
  final VoidCallback? onOpenLyrics;

  const QueuePanel({
    super.key,
    required this.open,
    this.width,
    this.onWidthDrag,
    this.onWidthDragEnd,
    this.onOpenArtist,
    this.onOpenLyrics,
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
        onOpenLyrics: onOpenLyrics,
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
    final darkContent = accent != null &&
        ArtworkPaletteService.prefersBlackInk(accent);
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

  /// Opens the lyrics container from the lyrics preview card.
  final VoidCallback? onOpenLyrics;

  const _QueueGlass({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
    this.onOpenLyrics,
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
            onOpenLyrics: onOpenLyrics,
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
  final VoidCallback? onOpenLyrics;

  const _QueuePanelTabs({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
    this.onOpenLyrics,
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
            onOpenLyrics: widget.onOpenLyrics,
            onToggleQueue: () => setState(() => _showNowPlaying = false),
          ),
        ),
      ],
    );
  }
}

/// Artwork 1:1 del now playing con el gesto de pausa compartido con el player
/// expandido de Android: al pausar encoge de forma sutil (0.955) y al
/// reproducir vuelve a 1.0.
///
/// El `AspectRatio` sigue reservando el hueco (el scale es una transformación,
/// no cambia el layout). El `Stream` de `playing` solo AVISA del cambio para
/// repintar; el tamaño se decide leyendo el estado REAL del servicio
/// (`player.isPlaying`) en cada build, de modo que nunca queda un valor
/// cacheado desincronizado (que es lo que dejaba el artwork pequeño tras
/// reanudar).
class NowPlayingArtwork extends StatelessWidget {
  final PlayerService player;

  /// URL o ruta local de la portada (`null`/vacío → [fallback]).
  final String? source;

  /// Radio de las esquinas redondeadas.
  final double radius;

  /// Placeholder cuando no hay portada.
  final Widget fallback;

  const NowPlayingArtwork({
    super.key,
    required this.player,
    required this.source,
    required this.fallback,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: StreamBuilder<bool>(
        stream: player.playing,
        initialData: player.isPlaying,
        builder: (context, _) {
          final playing = player.isPlaying;
          return AnimatedScale(
            scale: playing ? 1.0 : 0.955,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: CoverImage(source: source, fallback: fallback),
            ),
          );
        },
      ),
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

  /// Opens the full lyrics container from the preview card.
  final VoidCallback? onOpenLyrics;

  /// Switches the shell container back to the queue panel.
  final VoidCallback? onToggleQueue;

  const _NowPlayingPanel({
    required this.player,
    required this.theme,
    required this.l10n,
    this.onOpenArtist,
    this.onOpenLyrics,
    this.onToggleQueue,
  });

  @override
  State<_NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<_NowPlayingPanel> {
  StreamSubscription<Track?>? _trackSub;
  Track? _track;
  bool _isFavorite = false;

  /// Favoritos REACTIVO (misma receta que PlayerBar): stream de drift sobre
  /// la playlist de favoritos. El toggle del player (o de cualquier otra
  /// superficie) escribe en la BD y este stream repinta la card sin
  /// one-shots — antes el panel no escuchaba al botón del player.
  StreamSubscription<bool>? _favSub;
  int _favoritesId = -1;

  /// Artist card detail (listeners text). Resolved in background from the
  /// artist cache; `null` while loading or when the channel is unknown.
  YtmArtistDetail? _artistDetail;

  /// True while the channel is being resolved (background search fallback
  /// when the track has no channelId).
  bool _artistLoading = false;

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
      });
      _subscribeFavorite();
      unawaited(_loadArtistDetail());
    });
    unawaited(_setupFavorites());
    unawaited(_loadArtistDetail());
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _favSub?.cancel();
    super.dispose();
  }

  /// Resuelve el id de la playlist de favoritos (promesa serializada del
  /// db) y arma la suscripción del stream.
  Future<void> _setupFavorites() async {
    final db = context.read<AppDatabase>();
    final id = await db.ensureFavoritesPlaylist();
    if (!mounted) return;
    _favoritesId = id;
    _subscribeFavorite();
  }

  /// (Re)suscribe el stream de favoritos para la pista ACTUAL. Cualquier
  /// escritura externa (player bar, menús, panel) dispara el repaint.
  void _subscribeFavorite() {
    _favSub?.cancel();
    _favSub = null;
    if (_favoritesId < 0) return;
    final track = _track;
    if (track == null) {
      if (mounted && _isFavorite) setState(() => _isFavorite = false);
      return;
    }
    final db = context.read<AppDatabase>();
    _favSub = db.watchTrackInPlaylist(_favoritesId, track.id).listen((inside) {
      if (!mounted) return;
      setState(() => _isFavorite = inside);
    });
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

    // Skeleton block helper shared by the credits/lyrics placeholders.
    // (Ahora viven en [now_playing_cards.dart]: LyricsCardSkeleton y
    // CreditsCardSkeleton viajan con las cards.)

    Widget body;
    if (track == null) {
      body = _NowPlayingSkeleton(theme: theme, message: l10n.queueEmpty);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          NowPlayingArtwork(
            player: widget.player,
            source: track.thumbnailUrl,
            fallback: ColoredBox(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              child: Icon(
                Icons.music_note_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Title with the favorite toggle INLINE at the far right (no
          // extra row); the artist takes its own full-width line below.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  track.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
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
                    // El toggle consulta el estado REAL en la BD (no el del
                    // botón) y devuelve el resultado: se pinta de inmediato.
                    // El stream reactivo lo confirma/corrige después.
                    final nowFav = await toggleTrackFavorite(context, track);
                    if (mounted && nowFav != _isFavorite) {
                      setState(() => _isFavorite = nowFav);
                    }
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
          Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ArtistInfoCard(
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
          const SizedBox(height: 8),
          // Cards de letras + créditos EXTRAÍDAS a [NowPlayingExtras] para
          // compartirlas con el player expandido de Android. El panel solo
          // alimenta la pista actual (las cargas viven en el widget nuevo).
          NowPlayingExtras(
            track: track,
            theme: theme,
            l10n: l10n,
            onOpenLyrics: widget.onOpenLyrics,
          ),
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
        // Artist card placeholder: SAME shape as the real card (avatar +
        // name + listeners rows over the tinted container).
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0x1F000000),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 10),
              block(120, 12, r: 6),
              const SizedBox(height: 3),
              block(84, 10, r: 5),
            ],
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
