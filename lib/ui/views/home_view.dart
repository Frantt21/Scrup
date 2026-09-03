import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../playback.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';
import '../widgets/scrup_toasts.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/cover_image.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/player_bar.dart' show kPlayerClearance, kPlayerOverlayInset;

/// Pantalla de inicio: barra de búsqueda arriba y las reproducciones
/// recientes en un grid 1:1 de SOLO DOS FILAS (las columnas se acomodan al
/// ancho de la ventana; las demás recientes no se muestran). Las playlists
/// viven en el contenedor lateral.
class HomeView extends StatefulWidget {
  /// Se llama al enviar una búsqueda desde el inicio (AppShell cambia a la
  /// vista Buscar y le pasa la consulta).
  final ValueChanged<String>? onSearch;

  /// Se llama al pulsar el botón de búsqueda del header (AppShell navega a la
  /// vista Buscar sin consulta previa).
  final VoidCallback? onOpenSearch;

  /// Se llama al tocar una playlist reciente del inicio (AppShell abre su
  /// detalle).
  final ValueChanged<Playlist>? onOpenPlaylist;

  const HomeView({
    super.key,
    this.onSearch,
    this.onOpenSearch,
    this.onOpenPlaylist,
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
  StreamSubscription<List<Playlist>>? _recentPlaylistsSub;
  List<Playlist> _recentPlaylists = const [];

  /// Pista en reproducción (para el indicador de "en reproducción").
  Track? _currentTrack;
  bool _playing = false;
  Timer? _nullTrackTimer;

  /// Playlist activa en reproducción (para el indicador de "en reproducción"
  /// en las tarjetas de playlists recientes).
  int? _activePlaylistId;
  VoidCallback? _onActivePlaylistChanged;

  /// Card size and grid layout (desktop ~200px, mobile compact).
  static const _cardExtent = 200.0;
  static const _rows = 2;

  @override
  void initState() {
    super.initState();
    _recentStream = context.read<AppDatabase>().watchRecentlyPlayed(limit: 30);
    _sub = _recentStream.listen((tracks) {
      if (!mounted) return;
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
    _recentPlaylistsSub?.cancel();
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
    final themeController = context.watch<ThemeController>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool mobile = Binaries.isMobile;
        // Insets superiores: en móvil la vista se dibuja edge-to-edge (la
        // barra de estado queda detrás del degradado de acento), así que el
        // contenido se hunde con este inset para no quedar bajo la barra.
        final double topInset = MediaQuery.paddingOf(context).top;
        // Desktop: cards ~200px. Mobile: exactamente 3 COLUMNAS × 2 FILAS.
        final cols = mobile
            ? 3
            : ((constraints.maxWidth - 32) / (_cardExtent + 12)).floor().clamp(1, 10);
        final rows = mobile ? _rows : _rows;
        final visible = _recent.length.clamp(0, cols * rows);

        final recentPlaylists = _recentPlaylists;

        final Widget searchField = TextField(
          onSubmitted: _submitSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            filled: true,
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
                      ? SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16, topInset + 16, 16, 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                            child: searchField,
                          ),
                        ),
                  if (!_loaded)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  if (_loaded)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            mobile ? 16 : 24, 8, mobile ? 16 : 24, 12),
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
                        16, 0, 16, mobile ? 16 : kPlayerOverlayInset,
                      ),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: mobile ? 6 : 12,
                          crossAxisSpacing: mobile ? 6 : 12,
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
                  // Recent playlists (DESPUÉS del grid de recientes)
                  if (recentPlaylists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _RecentPlaylistsRow(
                        playlists: recentPlaylists,
                        accent: themeController.accentColor ??
                            theme.colorScheme.primary,
                        activePlaylistId: _activePlaylistId,
                        isPlaying: _playing,
                        onOpen: _openPlaylist,
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
              _TopAccentGradient(accent: themeController.accentColor),
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
            _TopAccentGradient(accent: themeController.accentColor),
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
            // Borde de 2px SOLO en la canción en reproducción (con el acento
            // de su artwork). El resto de las recientes no llevan borde.
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
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Artwork completo
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

/// Aviso compacto cuando no hay reproducciones recientes.
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

/// Degradado de acento en el TOP del Inicio: ocupa ~1/4 del alto y se
/// desvanece hacia abajo hasta transparente. Solo en el inicio.
class _TopAccentGradient extends StatelessWidget {
  final Color? accent;

  const _TopAccentGradient({this.accent});

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
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

/// Fila horizontal ÚNICA y scrolleable de playlists recientes, con cards más
/// grandes que las recientes (estilo forawn_mobile).
class _RecentPlaylistsRow extends StatelessWidget {
  final List<Playlist> playlists;
  final Color accent;
  final int? activePlaylistId;
  final bool isPlaying;
  final ValueChanged<Playlist> onOpen;

  const _RecentPlaylistsRow({
    required this.playlists,
    required this.accent,
    required this.activePlaylistId,
    required this.isPlaying,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (playlists.isEmpty) return const SizedBox.shrink();

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

/// Card grande de playlist reciente: portada 1:1 con el título DENTRO del
/// card (sobre el artwork, como las recientes) y el indicador de
/// "en reproducción" cuando la playlist está sonando.
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
    final width = 140.0;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
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
              // Título dentro del card (esquina inferior)
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
              // Indicador de "en reproducción" (igual que desktop)
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
