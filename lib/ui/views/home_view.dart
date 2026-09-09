import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';

import '../../core/binaries.dart';
import '../../core/app_log.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart' show YtmArtist;
import '../playback.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';
import '../widgets/scrup_toasts.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/cover_image.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/player_bar.dart' show kPlayerClearance, kPlayerOverlayInset;

/// Home screen: search bar on top and recent plays in a 1:1 grid of ONLY TWO ROWS (columns adjust to the window width; other recent tracks are not shown). Playlists live in the side container.
class HomeView extends StatefulWidget {
  /// Called when submitting a search from home (AppShell switches to the Search view and passes the query).
  final ValueChanged<String>? onSearch;

  /// Called when pressing the search button in the header (AppShell navigates to the Search view without a previous query).
  final VoidCallback? onOpenSearch;

  /// Called when tapping a recent playlist on home (AppShell opens its detail).
  final ValueChanged<Playlist>? onOpenPlaylist;

  /// Called when tapping a visited artist (AppShell opens the artist screen).
  final ValueChanged<YtmArtist>? onOpenArtist;

  const HomeView({
    super.key,
    this.onSearch,
    this.onOpenSearch,
    this.onOpenPlaylist,
    this.onOpenArtist,
  });

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  late final Stream<List<Track>> _recentStream;
  StreamSubscription<List<Track>>? _sub;
  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  List<Track> _recent = const [];
  bool _loaded = false;

  // Banner "Tus me gusta": últimas 3 canciones añadidas a favoritos
  // (portadas sobrepuestas). Stream reactivo: al dar like aparece al instante.
  Stream<List<Track>>? _likesStream;
  StreamSubscription<List<Track>>? _likesSub;
  List<Track> _likes = const [];
  StreamSubscription<List<Playlist>>? _recentPlaylistsSub;
  List<Playlist> _recentPlaylists = const [];

  // Artistas visitados (fila de home, igual que las playlists recientes).
  StreamSubscription<List<VisitedArtist>>? _visitedArtistsSub;
  List<VisitedArtist> _visitedArtists = const [];

  /// Debounce de recientes: ELIMINADO (forawn-style: instantáneo). El delay
  /// difería el rebuild pero se percibía como lag en la UI; con imágenes
  /// cacheadas el rebuild es barato. Se conserva el skip si no cambió nada.
  List<String> _recentIds = const [];

  static bool _sameIds(List<String> a, List<Track> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i].id) return false;
    }
    return true;
  }

  /// Pista en reproducción (para el indicador de "en reproducción").
  Track? _currentTrack;
  bool _playing = false;
  Timer? _nullTrackTimer;

  /// Playlist activa en reproducción (para el indicador de "en reproducción"
  /// en las tarjetas de playlists recientes).
  int? _activePlaylistId;
  VoidCallback? _onActivePlaylistChanged;

  @override
  void initState() {
    super.initState();
    // EXPERIMENTO kHideHomeRecents: sin suscripciones no hay datos ni
    // rebuilds de recientes; se marca cargado para no mostrar el spinner.
    if (kHideHomeRecents) {
      _loaded = true;
    } else {
      _recentStream = context.read<AppDatabase>().watchRecentlyPlayed(limit: 30);
      _sub = _recentStream.listen((tracks) {
        if (!mounted) return;
        // Skip si no cambió nada (emisiones redundantes del stream).
        if (_loaded && _sameIds(_recentIds, tracks)) return;
        _recentIds = [for (final t in tracks) t.id];
        setState(() {
          _recent = tracks;
          _loaded = true;
        });
      });
      _recentPlaylistsSub = context
          .read<AppDatabase>()
          .watchRecentPlaylists(limit: 12)
          .listen((playlists) {
        if (!mounted) return;
        setState(() => _recentPlaylists = playlists);
      });
      _visitedArtistsSub = context
          .read<AppDatabase>()
          .watchVisitedArtists(limit: 12)
          .listen((artists) {
        if (!mounted) return;
        setState(() => _visitedArtists = artists);
      });
      // Banner de favoritos (no bloquea _loaded: es optativo).
      unawaited(
        context.read<AppDatabase>().ensureFavoritesPlaylist().then((id) {
          if (!mounted) return;
          _likesStream = context
              .read<AppDatabase>()
              .watchLatestPlaylistTracks(id, limit: 3);
          _likesSub = _likesStream!.listen((tracks) {
            if (!mounted) return;
            setState(() => _likes = tracks);
          });
        }),
      );
    }
    // Indicador de "en reproducción" en las tarjetas
    final player = context.read<PlayerService>();
    _currentTrack = player.currentTrackValue;
    _playing = player.isPlaying;
    _activePlaylistId = player.activePlaylistId.value;
    _trackSub = player.currentTrack.listen((t) {
      if (!mounted) return;
      if (t == null) {
        _nullTrackTimer?.cancel();
        _nullTrackTimer = Timer(const Duration(milliseconds: 80), () {
          if (mounted) setState(() => _currentTrack = null);
        });
        return;
      }
      _nullTrackTimer?.cancel();
      // Las republicaciones del MISMO tema (p. ej. enrich al completar) solo
      // cambian metadatos; el indicador "en reproducción" usa el id → skip.
      if (t.id == _currentTrack?.id) return;
      setState(() => _currentTrack = t);
    });
    _playingSub = player.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
    _onActivePlaylistChanged = () {
      if (mounted) setState(() => _activePlaylistId = player.activePlaylistId.value);
    };
    player.activePlaylistId.addListener(_onActivePlaylistChanged!);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _trackSub?.cancel();
    _playingSub?.cancel();
    _likesSub?.cancel();
    _recentPlaylistsSub?.cancel();
    _visitedArtistsSub?.cancel();
    _nullTrackTimer?.cancel();
    if (_onActivePlaylistChanged != null) {
      context.read<PlayerService>().activePlaylistId.removeListener(
        _onActivePlaylistChanged!,
      );
    }
    super.dispose();
  }

  /// Abre el detalle de una playlist (lo gestiona el AppShell).
  void _openPlaylist(Playlist playlist) {
    widget.onOpenPlaylist?.call(playlist);
  }

  void _submitSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    widget.onSearch?.call(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool mobile = Binaries.isMobile;
        // Insets superiores: en móvil la vista se dibuja edge-to-edge (la
        // barra de estado queda detrás del degradado de acento), así que el
        // contenido se hunde con este inset para no quedar bajo la barra.
        final double topInset = MediaQuery.paddingOf(context).top;
        // Recientes: SIEMPRE 2 FILAS horizontales; las columnas se adaptan
        // al ancho disponible (cards cuadradas ~1:1). Móvil fija 3 columnas.
        const int rows = 2;
        final int cols = mobile
            ? 3
            : ((constraints.maxWidth - 48 + 10) / (140 + 10))
                  .floor()
                  .clamp(2, 8);
        // Tamaño EXACTO de la celda del grid de recientes (el SliverGrid
        // reparte: ancho - padding 48 - spacing (cols-1)*10, dividido en
        // cols). Las cards de playlists de desktop usan este mismo valor.
        final double cellExtent = mobile
            ? 0
            : (constraints.maxWidth - 48 - (cols - 1) * 10) / cols;
        final visible = _recent.length.clamp(0, cols * rows);

        final recentPlaylists = _recentPlaylists;

        // Campo de búsqueda (desktop): fondo TRANSLÚCIDO con BLUR (Back-
        // dropFilter sobre el degradado de acento que pasa por detrás). El
        // relleno sólido M3 ocultaba el degradado; el blur lo deja ver
        // difuminado. Sin bordes.
        final Widget searchField = TextField(
          onSubmitted: _submitSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            filled: true,
            fillColor: theme.colorScheme.surface.withValues(alpha: 0.45),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        );

        final Widget scroll = CustomScrollView(
                slivers: [
                  // En móvil: header ALINEADO con los demás screens: título
                  // "Scrup" a la izquierda + botón de búsqueda que navega a la
                  // vista Buscar. Al ser edge-to-edge, el header se hunde con
                  // el inset de la barra de estado (topInset) igual que las
                  // otras vistas con SafeArea. En desktop se mantiene el campo
                  // de búsqueda scrolleable dentro del panel.
                  mobile
                      ? SliverPersistentHeader(
                          // Header FIJO y transparente: siempre visible al
                          // scrollear (pinned) y sin fondo — el contenido y
                          // el degradado de acento pasan por detrás.
                          pinned: true,
                          floating: false,
                          delegate: _HomeHeaderDelegate(
                            topInset: topInset,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    'Scrup',
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed: widget.onOpenSearch,
                                  icon: const Icon(Icons.search_rounded),
                                  tooltip: l10n.searchHint,
                                ),
                              ],
                            ),
                          ),
                        )
                      : SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                            // BLUR real: el campo translúcido difumina el
                            // degradado de acento que pasa por detrás.
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 14,
                                  sigmaY: 14,
                                ),
                                child: searchField,
                              ),
                            ),
                          ),
                        ),
                  if (!_loaded)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  // ── Banner "Tus me gusta" ─────────────────────────
                  // Card a todo el ancho con el título a la izquierda y las
                  // 3 últimas portadas de favoritos sobrepuestas a la
                  // derecha. Reproduce los favoritos al tocarlo; oculto si
                  // no hay ningún favorito aún.
                  if (_loaded && _likes.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          mobile ? 16 : 24,
                          8,
                          mobile ? 16 : 24,
                          12,
                        ),
                        child: _YourLikesBanner(
                          likes: _likes,
                          title: l10n.yourLikes,
                          // Abre la playlist de favoritos REAL (su detalle,
                          // gestionado por el AppShell): no crea una cola
                          // nueva ni toca la reproducción.
                          onOpenPlaylist: () async {
                            final db = context.read<AppDatabase>();
                            final id = await db.ensureFavoritesPlaylist();
                            final pl = await db.getPlaylist(id);
                            if (pl != null && context.mounted) {
                              _openPlaylist(pl);
                            }
                          },
                        ),
                      ),
                    ),
                  if (_loaded)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            mobile ? 16 : 24, 4, mobile ? 16 : 24, 8),
                        child: _recent.isEmpty
                            ? _EmptyHint(theme: theme)
                            : Text(
                                l10n.recentTitle,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                  if (_loaded && _recent.isNotEmpty)
                    SliverPadding(
                      // El player flotante cubre la parte inferior: dejar espacio
                      // para que la última fila del grid quede accesible.
                      // En móvil no hay clearance (el mini-player vive aparte).
                      padding: EdgeInsets.fromLTRB(
                        mobile ? 16 : 24, 0, mobile ? 16 : 24, mobile ? 16 : kPlayerOverlayInset,
                      ),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: mobile ? 6 : 10,
                          crossAxisSpacing: mobile ? 6 : 10,
                          childAspectRatio: 1,
                        ),
                        delegate: SliverChildBuilderDelegate((context, i) {
                          final track = _recent[i];
                          return _RecentCard(
                            track: track,
                            onPlay: () => playTrack(context, track),
                            isCurrent: track.id == _currentTrack?.id,
                            isPlaying: _playing,
                          );
                        }, childCount: visible),
                      ),
                    ),
                  // Recent playlists (DESPUÉS del grid de recientes).
                  // Desktop: GRID del MISMO tamaño que las cards de
                  // recientes (mismas columnas que el grid de arriba).
                  if (recentPlaylists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: mobile
                          ? _RecentPlaylistsRow(
                              playlists: recentPlaylists,
                              activePlaylistId: _activePlaylistId,
                              isPlaying: _playing,
                              onOpen: _openPlaylist,
                            )
                          : _RecentPlaylistsGrid(
                              playlists: recentPlaylists,
                              cols: cols,
                              cardExtent: cellExtent,
                              activePlaylistId: _activePlaylistId,
                              isPlaying: _playing,
                              onOpen: _openPlaylist,
                            ),
                    ),
                  // Artistas visitados (DESPUÉS de las playlists recientes,
                  // mismo estilo de fila horizontal)
                  if (_visitedArtists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _VisitedArtistsRow(
                        artists: _visitedArtists,
                        onOpen: widget.onOpenArtist,
                      ),
                    ),
                  // Espacio inferior: desktop despeja el player flotante.
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: mobile ? 16 : kPlayerOverlayInset,
                    ),
                  ),
                ],
              );

        // En móvil: el degradado de acento pega arriba del todo, detrás del
        // contenido, y no hay margen despejado con el fondo de la ventana.
        if (mobile) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _TopAccentGradient(),
              scroll,
            ],
          );
        }

        // ── Escritorio ──
        // El degradado de acento vive DENTRO del cristal, arriba, detrás del
        // contenido, ocupando ~1/4 del alto del panel y desvaneciéndose.
        final Widget inner = Stack(
          fit: StackFit.expand,
          children: [
            _TopAccentGradient(),
            scroll,
          ],
        );

        return Container(
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
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.72,
                ),
              ),
              child: inner,
            ),
          ),
        );
      },
    );
  }
}


/// Tarjeta cuadrada con el artwork completo y título/artista en la esquina
/// inferior, con un hover que muestra el botón de play (sin animación de
/// escala).
class _RecentCard extends StatefulWidget {
  final Track track;
  final VoidCallback onPlay;
  final bool isCurrent;
  final bool isPlaying;

  const _RecentCard({
    required this.track,
    required this.onPlay,
    this.isCurrent = false,
    this.isPlaying = false,
  });

  @override
  State<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends State<_RecentCard> {
  bool _hovered = false;

  /// Menú contextual (clic derecho) sobre la tarjeta: añadir a playlist.
  Future<void> _showMenu(Offset position) async {
    final l10n = AppLocalizations.of(context);
    final action = await showMenu<String>(
      context: context,
      // Anclaje correcto: recta de tamaño cero en la posición del cursor.
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      // Recortar el menú a sus esquinas redondeadas: con el menuPadding a
      // cero, el hover de los items queda full-bleed sin desbordar.
      clipBehavior: Clip.antiAlias,
      items: [
        ContextMenuItem(
          value: 'add',
          icon: Icons.playlist_add_rounded,
          label: l10n.addToPlaylist,
        ),
        ContextMenuItem(
          value: 'recalc',
          icon: Icons.palette_rounded,
          label: l10n.recalcColors,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await showAddToPlaylistDialog(context, widget.track);
    } else if (action == 'recalc') {
      final url = widget.track.thumbnailUrl;
      if (url != null && url.isNotEmpty) {
        final store = context.read<PaletteCacheStore>();
        await ArtworkPaletteService.trioFor(
          url,
          store,
          force: true,
          artworkCache: context.read<ArtworkCacheService>(),
        );
        if (mounted) {
          showScrupToast(l10n.colorsUpdated, kind: ScrupToastKind.success);
        }
      }
    }
  }

  /// Bottom sheet contextual (long press) en móvil.
  Future<void> _showMobileMenu() async {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final track = widget.track;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: CoverImage(
                        source: track.thumbnailUrl,
                        fit: BoxFit.cover,
                        fallback: Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note_rounded,
                            size: 24,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist.isEmpty
                              ? l10n.unknownArtist
                              : track.artist,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: Text(l10n.addToPlaylist),
              onTap: () => Navigator.pop(ctx, 'add'),
            ),
            ListTile(
              leading: const Icon(Icons.palette_rounded),
              title: Text(l10n.recalcColors),
              onTap: () => Navigator.pop(ctx, 'recalc'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await showAddToPlaylistDialog(context, widget.track);
    } else if (action == 'recalc') {
      final url = widget.track.thumbnailUrl;
      if (url != null && url.isNotEmpty) {
        final store = context.read<PaletteCacheStore>();
        await ArtworkPaletteService.trioFor(
          url,
          store,
          force: true,
          artworkCache: context.read<ArtworkCacheService>(),
        );
        if (mounted) {
          showScrupToast(l10n.colorsUpdated, kind: ScrupToastKind.success);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = widget.track;

    // Acento de 1px del borde: el acento derivado del artwork de la canción
    // (fallback al primary del tema si la paleta aún no está cacheada).
    final accent = _accentFor(track, theme);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
        onLongPress: _showMobileMenu,
        onTap: widget.onPlay,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: widget.isCurrent
                ? Border.all(
                    width: 2,
                    color: accent.withValues(
                      alpha: _hovered ? 0.9 : 0.7,
                    ),
                  )
                : null,
          ),
          child: ClipRRect(
            // canción en reproducción.
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _artwork(theme),
                // Gradiente inferior para legibilidad del texto
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                      stops: [0.5, 1.0],
                    ),
                  ),
                ),
                // Título + artista en la esquina inferior
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                // Play al hacer hover
                if (_hovered)
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                // Indicador limpio: solo el ecualizador (la sombra del
                // widget lo hace legible sobre el artwork)
                if (widget.isCurrent)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: NowPlayingBars(active: widget.isPlaying, size: 13),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Acento de la canción: trío cacheado → accent (fallback primary).
  Color _accentFor(Track track, ThemeData theme) {
    final url = track.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      final trio = context.read<PaletteCacheStore>().getTrio(url);
      final accent = trio == null ? null : ArtworkPaletteService.accentFromTrio(trio);
      if (accent != null) return accent;
    }
    return theme.colorScheme.primary;
  }

  Widget _artwork(ThemeData theme) {
    // HI-RES: el grid muestra ~200px (×DPR); la miniatura por defecto de
    // InnerTube se ve borrosa. hiResThumbnail remapea ytimg→maxres y las
    // URLs de googleusercontent a su variante 1200px; rutas locales pasan
    // tal cual. cacheWidth limita el decode al tamaño real necesario.
    return CoverImage(
      source: Track.hiResThumbnail(widget.track.thumbnailUrl),
      fit: BoxFit.cover,
      cacheWidth: 500,
      fallback: Container(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Icon(
          Icons.music_note_rounded,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Banner "Tus me gusta" de home: título a la izquierda + las 3 últimas
/// portadas de favoritos sobrepuestas a la derecha. Tocarlo abre la
/// playlist de favoritos (no crea una cola nueva).
class _YourLikesBanner extends StatelessWidget {
  final List<Track> likes;
  final String title;
  final VoidCallback? onOpenPlaylist;

  const _YourLikesBanner({
    required this.likes,
    required this.title,
    required this.onOpenPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    // Portadas sobrepuestas 1:1 (mismo radio 18dp que el artwork del
    // player), SIN borde. La más reciente ENCIMA; la última PEGA al borde
    // derecho del banner (sin margen: el ClipRRect del banner recorta la
    // esquina por el radio 16, como las covers de playlists).
    const double coverRadius = 18.0;
    // ALTURA FIJA de la pila: dentro de un sliver la altura no viene
    // acotada (double.infinity en contexto sin límite = excepción de
    // layout que dejaba el home entero en blanco tras el header).
    const double bannerHeight = 72.0;
    final covers = <Widget>[];
    for (var i = 0; i < likes.length && i < 3; i++) {
      final t = likes[i];
      covers.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(coverRadius),
          child: SizedBox.expand(
            child: CoverImage(
              source: t.thumbnailUrl != null
                  ? (Track.hiResThumbnail(t.thumbnailUrl) ?? t.thumbnailUrl)
                  : null,
              fit: BoxFit.cover,
              cacheWidth: 128,
              fallback: ColoredBox(
                color: accent.withValues(alpha: 0.25),
                child: Icon(
                  Icons.favorite_rounded,
                  size: 20,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenPlaylist,
        child: Padding(
          // Solo padding IZQUIERDO: la pila de portadas llega hasta el borde
          // derecho real del card (la tercera queda pegada al extremo).
          padding: const EdgeInsets.only(left: 14),
          child: Row(
            children: [
              Icon(Icons.favorite_rounded, color: accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              // Pila 1:1: cada cover mide bannerHeight (cuadrada), la más
              // reciente encima desplazada 30px a la izquierda. La última
              // (más vieja) queda alineada al borde derecho SIN margen.
              SizedBox(
                width: bannerHeight + (covers.length - 1) * 30.0,
                height: bannerHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = covers.length - 1; i >= 0; i--)
                      Positioned(
                        right: i * 30.0,
                        top: 0,
                        bottom: 0,
                        width: bannerHeight,
                        child: covers[i],
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

class _EmptyHint extends StatelessWidget {
  final ThemeData theme;

  const _EmptyHint({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.history_rounded,
          size: 40,
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 8),
        Text(
          AppLocalizations.of(context).recentEmptyTitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          AppLocalizations.of(context).recentEmptyHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

/// Accent gradient at the TOP of Home: takes ~1/4 of the height and fades downward to transparent. Only on home.
class _TopAccentGradient extends StatelessWidget {
  const _TopAccentGradient();

  @override
  Widget build(BuildContext context) {
    // Isolated reactive leaf: listens ONLY to the accent. Before this, the whole HomeView did `context.watch<ThemeController>()` in its build and every accent change (one per track change) rebuilt the whole scroll + grid, even with the player on top.
    final color =
        context.watch<ThemeController>().accentColor ??
        Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        // Solo el ~1/4 superior: el degradado se desvanece hacia abajo y el
        // resto del inicio queda sin tinte (antes ocupaba todo el alto).
        child: FractionallySizedBox(
          heightFactor: 0.27,
          widthFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.35),
                  color.withValues(alpha: 0.18),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Header FIJO de home (móvil): pinned y SIN fondo — el contenido pasa por
/// detrás al scrollear. Reproduce el layout del header original (título +
/// botón de búsqueda hundido con el inset de la barra de estado).
class _HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  _HomeHeaderDelegate({required this.topInset, required this.child});

  final double topInset;
  final Widget child;

  static const double _contentH = 56.0;

  @override
  double get minExtent => topInset + _contentH;

  @override
  double get maxExtent => topInset + _contentH;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Sin fondo a propósito (transparente); padding lateral 16 + vertical
    // como el header original.
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topInset + 16, 16, 8),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_HomeHeaderDelegate oldDelegate) =>
      oldDelegate.topInset != topInset || oldDelegate.child != child;
}

/// Fila horizontal de ARTISTAS visitados: mismo estilo que las playlists
/// recientes (cards 140dp con título dentro). La miniatura viene de la
/// visita; si el canal cambió su avatar, el screen del artista lo trae
/// fresco al abrir (la visita se repuebla con la nueva URL).
class _VisitedArtistsRow extends StatelessWidget {
  final List<VisitedArtist> artists;
  final ValueChanged<YtmArtist>? onOpen;

  const _VisitedArtistsRow({required this.artists, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (artists.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            l10n.visitedArtistsTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 158,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.length,
            itemBuilder: (context, i) {
              final a = artists[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _VisitedArtistCard(
                  artist: a,
                  onTap: () => onOpen?.call(
                    YtmArtist(
                      browseId: a.id,
                      name: a.name,
                      // Avatar REAL guardado con la visita: la card pinta
                      // la cara del canal, nunca un placeholder vacío.
                      thumbnailUrl: a.thumbnailUrl,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Card de artista visitado (idéntica a la de playlist reciente: 140dp,
/// portada 1:1 completa con el título dentro).
class _VisitedArtistCard extends StatelessWidget {
  final VisitedArtist artist;
  final VoidCallback onTap;

  const _VisitedArtistCard({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = artist.thumbnailUrl != null &&
        artist.thumbnailUrl!.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      // 1:1 REAL: 140×140 centrado en la fila de 158 (antes la card
      // estiraba al alto de la fila → 140×158, sin relación 1:1).
      child: Center(
        child: SizedBox(
          width: 140,
          height: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasCover)
                CoverImage(
                  source: artist.thumbnailUrl,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  fallback: Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.person_rounded,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Container(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Icon(
                    Icons.person_rounded,
                    size: 44,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                    stops: [0.5, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  artist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Desktop: playlist cards EN GRID (mismas columnas/tamaño que las cards
/// de recientes) — la fila horizontal scrolleable es cosa de móvil.
class _RecentPlaylistsGrid extends StatelessWidget {
  final List<Playlist> playlists;
  final int cols;

  /// Tamaño de card = celda EXACTA del grid de recientes.
  final double cardExtent;
  final int? activePlaylistId;
  final bool isPlaying;
  final ValueChanged<Playlist> onOpen;

  const _RecentPlaylistsGrid({
    required this.playlists,
    required this.cols,
    required this.cardExtent,
    required this.activePlaylistId,
    required this.isPlaying,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.watch<ThemeController>().accentColor ??
        theme.colorScheme.primary;
    if (playlists.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              AppLocalizations.of(context).recentPlaylistsTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Máx. 2 filas como el grid de recientes.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final playlist in playlists.take(cols * 2))
                SizedBox(
                  width: cardExtent,
                  height: cardExtent,
                  child: _RecentPlaylistCard(
                    playlist: playlist,
                    accent: accent,
                    isCurrent: playlist.id == activePlaylistId,
                    isPlaying: isPlaying,
                    onTap: () => onOpen(playlist),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fila horizontal ÚNICA y scrolleable de playlists recientes, con cards más
/// grandes que las recientes (estilo forawn_mobile).
class _RecentPlaylistsRow extends StatelessWidget {
  final List<Playlist> playlists;
  final int? activePlaylistId;
  final bool isPlaying;
  final ValueChanged<Playlist> onOpen;

  const _RecentPlaylistsRow({
    required this.playlists,
    required this.activePlaylistId,
    required this.isPlaying,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (playlists.isEmpty) return const SizedBox.shrink();
    // Acento propio (watch local): un cambio de acento reconstruye solo esta
    // fila, no todo el HomeView.
    final accent = context.watch<ThemeController>().accentColor ??
        theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            l10n.recentPlaylistsTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 158,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: playlists.length,
            itemBuilder: (context, i) {
              final playlist = playlists[i];
              final isCurrent = playlist.id == activePlaylistId;
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _RecentPlaylistCard(
                  playlist: playlist,
                  accent: accent,
                  isCurrent: isCurrent,
                  isPlaying: isPlaying,
                  onTap: () => onOpen(playlist),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Large recent playlist card: 1:1 cover with the title INSIDE the card (over the artwork, like the recent tracks) and the "now playing" indicator when the playlist is playing.
class _RecentPlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final Color accent;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;

  const _RecentPlaylistCard({
    required this.playlist,
    required this.accent,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      // Llena el SizedBox del padre: móvil fija 140 (fila) y desktop la
      // celda EXACTA del grid de recientes (mismo tamaño que esas cards).
      child: SizedBox.expand(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Portada completa 1:1
              if (hasCover)
                CoverImage(
                  source: playlist.coverUrl!,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  fallback: Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.queue_music_rounded,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accent, accent.withValues(alpha: 0.6)],
                    ),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    size: 44,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              // Gradiente inferior para legibilidad del texto
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                    stops: [0.5, 1.0],
                  ),
                ),
              ),
              // Title inside the card (bottom corner)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  playlist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // "Now playing" indicator (same as desktop)
              if (isCurrent)
                Positioned(
                  top: 10,
                  left: 10,
                  child: NowPlayingBars(active: isPlaying, size: 13),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
