import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart';
import '../playlist_actions.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_tile.dart';

/// Readable text over a background of the given color (black/white by luminance).
Color _onColor(Color bg) =>
    bg.computeLuminance() > 0.5 ? Colors.black : Colors.white;

/// Artist detail (Android/desktop): data from the InnerTube channel page (top songs + albums) with its own 24h cache.
///
/// Header with PLAYLIST DETAIL style and FULL ARTWORK: the channel image spans the full width (edge-to-edge, behind the status bar) with a gradient that blends into the background color — the same look as the playlist detail in its default style. Buttons use the accent EXTRACTED from the channel image (not the global theme primary). Scrolling shows the artist name in the collapsed appbar. It is mounted INSIDE the shell (nav + miniplayer present).
class ArtistDetailView extends StatefulWidget {
  const ArtistDetailView({super.key, required this.artist, this.onBack});

  /// Artist derived from the search: channel + name (no avatar: the real face arrives with the detail).
  final YtmArtist artist;

  /// Returns to the search. On mobile it is provided by AppShell (screen mounted in the shell); if null, it pops the Navigator (desktop).
  final VoidCallback? onBack;

  @override
  State<ArtistDetailView> createState() => _ArtistDetailViewState();
}

class _ArtistDetailViewState extends State<ArtistDetailView> {
  YtmArtistDetail? _detail;
  bool _loading = true;
  String? _error;

  bool _showPinnedTitle = false;

  /// Acento extraído de la imagen del canal (mismo camino que el detalle de playlist: PaletteCacheStore + ArtworkPaletteService). Pinta los botones y tiñe el fondo (lerp 0.30, igual que el playlist completo).
  Color? _accent;
  String? _accentFor;

  /// Álbum abierto: se muestra EMBEBIDO (en vez del contenido del artista, sin push de ruta) — nav + miniplayer visibles.
  YtmAlbum? _openedAlbum;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = context.read<SearchService>();
      final detail = await svc.fetchArtistDetail(
        widget.artist.browseId,
        name: widget.artist.name,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _error = detail == null ? 'no-data' : null;
      });
      unawaited(_maybeExtractAccent(detail?.thumbnailUrl));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'network';
      });
    }
  }

  /// Extract the accent from the channel image (cached in the PaletteCacheStore — same shared store as the playlists).
  Future<void> _maybeExtractAccent(String? thumb) async {
    if (thumb == null || thumb.isEmpty || thumb == _accentFor) return;
    _accentFor = thumb;
    final store = context.read<PaletteCacheStore>();
    final stored = store.get(thumb);
    if (stored != null) {
      setState(() => _accent = stored);
      return;
    }
    if (store.isFailed(thumb)) return;
    Color? color;
    try {
      final trio = await ArtworkPaletteService.trioFor(
        thumb,
        store,
        artworkCache: context.read<ArtworkCacheService>(),
      );
      color = trio.isEmpty
          ? null
          : (ArtworkPaletteService.accentFromTrio(trio) ?? trio.first);
    } catch (_) {
      color = null;
    }
    if (!mounted || color == null) return;
    setState(() => _accent = color);
  }

  void _playAll() {
    final detail = _detail;
    if (detail == null || detail.tracks.isEmpty) return;
    unawaited(
      context.read<PlayerService>().playQueue([
        for (final t in detail.tracks) t.toTrack(),
      ]),
    );
  }

  void _playTrack(Track track, int index) {
    final detail = _detail;
    if (detail == null) return;
    unawaited(
      context.read<PlayerService>().playQueue([
        for (final t in detail.tracks) t.toTrack(),
      ], startIndex: index),
    );
  }

  /// Álbum → muestra su tracklist EMbebIDO (sin Navigator.push): el
  /// spinner vive DENTRO de esa vista mientras trae las pistas.
  Future<void> _openAlbum(YtmAlbum album) async {
    setState(() => _openedAlbum = album);
  }

  void _back() {
    if (_openedAlbum != null) {
      setState(() => _openedAlbum = null);
      return;
    }
    final cb = widget.onBack;
    if (cb != null) {
      cb();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Umbral (offset de scroll) a partir del cual la appbar colapsada muestra el nombre: justo antes de que el header expandido salga de pantalla.
  double _titleThreshold(double expandedHeight) =>
      (expandedHeight - 90).clamp(0.0, double.infinity);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final detail = _detail;

    // Tracklist de álbum abierto: vista EMbebIDA (mismo hueco del shell,
    // sin push de ruta — nav + miniplayer siguen visibles).
    final album = _openedAlbum;
    if (album != null) {
      return ArtistAlbumView(album: album, onBack: _back, artistAccent: _accent);
    }

    // Fondo con el color EXTRAÍDO de la imagen (mismo lerp 0.30 que el
    // detalle de playlist en su estilo full-bleed): sin costura entre el
    // header y el contenido.
    final Color bgColor = _accent == null
        ? theme.colorScheme.surface
        : (Color.lerp(
                theme.colorScheme.surfaceContainerHighest,
                _accent,
                0.30,
              ) ??
              theme.colorScheme.surface);

    final bool loading = _loading && detail == null;
    final double expandedH = MediaQuery.sizeOf(context).width * 0.95;
    final String name = (detail?.name.isNotEmpty ?? false)
        ? detail!.name
        : widget.artist.name;

    return Scaffold(
      backgroundColor: bgColor,
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final visible = n.metrics.pixels > _titleThreshold(expandedH);
          if (visible != _showPinnedTitle) {
            setState(() => _showPinnedTitle = visible);
          }
          return false;
        },
        child: Stack(
          children: [
            CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                // ── Header FULL ARTWORK (como la playlist detail) ──────
                SliverAppBar(
                  expandedHeight: expandedH,
                  pinned: true,
                  stretch: true,
                  stretchTriggerOffset: 60,
                  // Colapsado: fondo SÓLIDO del color del ambiente (nunca
                  // transparente: el nombre se lee siempre).
                  backgroundColor: bgColor,
                  elevation: 0,
                  automaticallyImplyLeading: false,
                  centerTitle: true,
                  // Nombre del artista SOLO cuando el header está colapsado.
                  title: AnimatedOpacity(
                    opacity: _showPinnedTitle ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.pin,
                    stretchModes: const [
                      StretchMode.zoomBackground,
                      StretchMode.blurBackground,
                    ],
                    background: _FullArtHeader(
                      detail: detail,
                      loading: loading,
                      bgColor: bgColor,
                    ),
                  ),
                ),
                // ── Info + acciones ─────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                    child: Column(
                      children: [
                        Text(
                          name,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (detail?.audienceText != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            detail!.audienceText!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 16),
                        if (detail != null && detail.tracks.isNotEmpty)
                          FilledButton.icon(
                            onPressed: _playAll,
                            // Acento EXTRAÍDO del canal (no el primary del
                            // tema global), como los botones del detalle de
                            // playlist usan el ambiente de su portada.
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              backgroundColor: _accent,
                              foregroundColor: _onColor(
                                _accent ?? theme.colorScheme.primary,
                              ),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(l10n.play),
                          ),
                      ],
                    ),
                  ),
                ),
                // ── Estados de carga / error ────────────────────────────
                if (loading)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null || detail == null)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_off_rounded,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(l10n.artistDetailEmpty),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _load,
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: _onColor(
                                _accent ?? theme.colorScheme.primary,
                              ),
                            ),
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  // ── Top canciones ─────────────────────────────────────
                  if (detail.tracks.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          l10n.artistTopTracks,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  SliverList.builder(
                    itemCount: detail.tracks.length,
                    itemBuilder: (context, i) {
                      final r = detail.tracks[i];
                      final track = r.toTrack();
                      return TrackTile(
                        track: track,
                        // Reproducciones de la canción ("1.2M plays").
                        subtitleSuffix: r.playCountText,
                        onPlay: () => _playTrack(track, i),
                        onAddToPlaylist: () =>
                            showAddToPlaylistDialog(context, track),
                      );
                    },
                  ),
                  // ── Álbumes: UNA SOLA FILA horizontal scrolleable ─────
                  if (detail.albums.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: Text(
                          l10n.artistAlbums,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        // Portada 140 + título (1 línea) + año.
                        height: 186,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: detail.albums.length,
                          itemBuilder: (context, i) {
                            final album = detail.albums[i];
                            return Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: _AlbumCard(
                                album: album,
                                onTap: () => unawaited(_openAlbum(album)),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 24),
                  ),
                ],
              ],
            ),
            // Back flotante SIEMPRE visible (sobre el artwork y sobre la
            // appbar colapsada). NEUTRO: sin color de acento.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _floatingCircleBtn(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _floatingCircleBtn(BuildContext context) {
    final theme = Theme.of(context);
    // Con el header colapsado activo (nombre visible) el back va SIN fondo:
    // sobre el fondo sólido del ambiente el círculo sobra. Expandido (sobre
    // el artwork) conserva el fondo neutro para legibilidad.
    final collapsed = _showPinnedTitle;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: collapsed
            ? Colors.transparent
            : theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          Icons.arrow_back_rounded,
          size: 20,
          color: theme.colorScheme.onSurface,
        ),
        onPressed: _back,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Header FULL ARTWORK (estilo playlist full-bleed): la imagen del canal a
/// TODO EL ALTO del flexible space con degradado inferior que funde al
/// color de fondo (mismos stops que la playlist detail).
class _FullArtHeader extends StatelessWidget {
  const _FullArtHeader({
    required this.detail,
    required this.loading,
    required this.bgColor,
  });

  final YtmArtistDetail? detail;
  final bool loading;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = detail?.thumbnailUrl;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Imagen COMPLETA a todo el ancho (edge-to-edge).
        if (thumb != null && thumb.isNotEmpty)
          CoverImage(
            source: thumb,
            fit: BoxFit.cover,
            cacheWidth: 1200,
            fallback: DecoratedBox(
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
              child: Center(
                child: Icon(
                  Icons.person_rounded,
                  size: 80,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          DecoratedBox(
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
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Icon(
                      Icons.person_rounded,
                      size: 80,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
            ),
          ),
        // Degradado inferior: funde al color de fondo (sin costura) —
        // mismos stops que el header full-bleed de la playlist detail.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.18),
                Colors.transparent,
                bgColor.withValues(alpha: 0.75),
                bgColor,
              ],
              stops: const [0.0, 0.38, 0.78, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// Card de álbum para la FILA HORIZONTAL: portada 1:1 a tamaño completo
/// (140dp, mismo tamaño que las cards de playlists recientes del home) +
/// título + año debajo. SIN loader en la card: el toque abre la vista del
/// tracklist, que muestra el spinner mientras carga.
class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final YtmAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = album.thumbnailUrl;
    const width = 140.0;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Portada 1:1 COMPLETA (todo el ancho del card).
            SizedBox(
              width: width,
              height: width,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: thumb != null && thumb.isNotEmpty
                    ? CoverImage(
                        source: thumb,
                        fit: BoxFit.cover,
                        cacheWidth: 500,
                        fallback: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.album_rounded,
                            size: 40,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.album_rounded,
                          size: 40,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (album.year != null)
              Text(
                album.year!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}  /// Tracklist de un álbum, con el MISMO estilo que el detalle de playlist en modo "acento plano" (flat): fondo del color del acento (extraído de la PROPIA portada del álbum, fallback al acento del artista), portada 1:1 centrada, título y botones de Play y Shuffle. Vista embebida (sin push de ruta): el spinner de carga vive AQUÍ, nunca en la card de la fila.
  class ArtistAlbumView extends StatefulWidget {
  const ArtistAlbumView({
    super.key,
    required this.album,
    this.onBack,
    this.artistAccent,
  });

  final YtmAlbum album;

  /// Volver (vista embebida dentro del detalle de artista). Si es null se
  /// hace pop del Navigator (push de ruta en desktop).
  final VoidCallback? onBack;

  /// Acento del artista (extraído de su imagen): fallback mientras se
  /// extrae el de la portada del álbum.
  final Color? artistAccent;

  @override
  State<ArtistAlbumView> createState() => _ArtistAlbumViewState();
}

class _ArtistAlbumViewState extends State<ArtistAlbumView> {
  List<Track>? _tracks;
  Color? _accent;
  String? _accentFor;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_extractAccent());
  }

  Future<void> _load() async {
    try {
      final tracks = await context
          .read<SearchService>()
          .fetchAlbumTracks(widget.album.playlistId);
      if (!mounted) return;
      setState(() => _tracks = tracks);
      // El acento depende de la portada; por si la recarga la actualizó.
      unawaited(_extractAccent());
    } catch (_) {
      if (!mounted) return;
      setState(() => _tracks = const []);
    }
  }

  /// Recarga FORZANDO la re-lectura de InnerTube (menú 3 puntos).
  Future<void> _reload() async {
    setState(() => _tracks = null);
    try {
      final tracks = await context
          .read<SearchService>()
          .reloadAlbumTracks(widget.album.playlistId);
      if (!mounted) return;
      setState(() => _tracks = tracks);
      unawaited(_extractAccent());
    } catch (_) {
      if (!mounted) return;
      setState(() => _tracks = const []);
    }
  }

  /// Acento de la PROPIA portada del álbum (mismo almacén de paletas que
  /// las playlists); fallback al acento del artista.
  Future<void> _extractAccent() async {
    final url = widget.album.thumbnailUrl;
    if (url == null || url.isEmpty || url == _accentFor) return;
    _accentFor = url;
    final store = context.read<PaletteCacheStore>();
    final stored = store.get(url);
    if (stored != null) {
      setState(() => _accent = stored);
      return;
    }
    if (store.isFailed(url)) return;
    Color? color;
    try {
      final trio = await ArtworkPaletteService.trioFor(
        url,
        store,
        artworkCache: context.read<ArtworkCacheService>(),
      );
      color = trio.isEmpty
          ? null
          : (ArtworkPaletteService.accentFromTrio(trio) ?? trio.first);
    } catch (_) {
      color = null;
    }
    if (!mounted || color == null) return;
    setState(() => _accent = color);
  }

  Future<void> _playAll() async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    await context.read<PlayerService>().playQueue(tracks);
  }

  /// Igual que el detalle de playlist: activa shuffle si no está activo y
  /// reproduce toda la lista.
  Future<void> _playShuffled() async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    final player = context.read<PlayerService>();
    if (!player.shuffle.value) player.toggleShuffle();
    await player.playQueue(tracks);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final tracks = _tracks;

    // "Flat accent": el fondo de TODO el screen comparte un único color
    // derivado del acento (lerp surface 0.55, igual que la playlist flat).
    final Color accent = _accent ?? widget.artistAccent ?? theme.primaryColor;
    final Color flatColor =
        Color.lerp(theme.colorScheme.surface, accent, 0.55) ??
        theme.colorScheme.surface;

    Widget buttonRow() => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: (tracks == null || tracks.isEmpty) ? null : _playAll,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: accent,
            foregroundColor: _onColor(accent),
          ),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.play),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: (tracks == null || tracks.isEmpty) ? null : _playShuffled,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: accent,
            foregroundColor: _onColor(accent),
          ),
          icon: const Icon(Icons.shuffle_rounded),
          label: Text(l10n.shuffle),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: flatColor,
      // MISMO estilo que la playlist detail móvil en modo "acento plano":
      // SliverAppBar SIN pin (el hero se va entero al scrollear — nunca hay
      // un segundo header), portada 1:1 alineada al tope bajo 110dp y los
      // controles flotantes como overlay EXTERNO al scroll.
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── Header: SOLO portada (idéntico al flat de playlist) ──
              SliverAppBar(
                expandedHeight: MediaQuery.sizeOf(context).width * 0.95,
                pinned: false,
                floating: false,
                snap: false,
                stretch: true,
                stretchTriggerOffset: 60,
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  stretchModes: const [
                    StretchMode.zoomBackground,
                    StretchMode.blurBackground,
                  ],
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: flatColor),
                      if (widget.album.thumbnailUrl?.isNotEmpty ?? false)
                        Padding(
                          // Igual que playlist flat: la portada nace DEBAJO
                          // de los controles flotantes (top 110).
                          padding: const EdgeInsets.only(top: 110),
                          child: Center(
                            child: FractionallySizedBox(
                              widthFactor: 0.6,
                              alignment: Alignment.topCenter,
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: CoverImage(
                                    source: widget.album.thumbnailUrl,
                                    fit: BoxFit.cover,
                                    cacheWidth: 900,
                                    fallback: Container(
                                      color: Colors.black26,
                                      child: const Center(
                                        child: Icon(
                                          Icons.album_rounded,
                                          size: 80,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        const Center(
                          child: Icon(Icons.album_rounded, size: 120),
                        ),
                    ],
                  ),
                ),
              ),
              // ── Info + acciones (mismo padding que la playlist) ──────
              SliverToBoxAdapter(child: _albumInfo(theme, l10n, buttonRow)),
              if (tracks == null)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (tracks.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.album_rounded,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(l10n.searchNoResults),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: _onColor(accent),
                          ),
                          child: Text(l10n.retry),
                        ),
                      ],
                    ),
                  ),
                )
              else
                // Lista con el MISMO padding que la playlist móvil.
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 100),
                  sliver: SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) {
                      final track = tracks[i];
                      return TrackTile(
                        track: track,
                        onPlay: () => unawaited(
                          context.read<PlayerService>().playQueue(
                            tracks,
                            startIndex: i,
                          ),
                        ),
                        onAddToPlaylist: () =>
                            showAddToPlaylistDialog(context, track),
                      );
                    },
                  ),
                ),
            ],
          ),
          // ── Controles flotantes EXTERNOS al scroll (como playlist) ───
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              // Padding ALINEADO con la playlist detail: (16, 16, 16, 8).
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    _floatingCircleBtn(
                      context,
                      Icons.arrow_back_rounded,
                      widget.onBack ?? () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _floatingCircleBtn(
                      context,
                      Icons.more_vert_rounded,
                      _showAlbumMenu,
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

  /// Botón circular flotante del header: MISMO estilo que la playlist
  /// detail móvil (40×40, círculo al acento, icono contrastado).
  Widget _floatingCircleBtn(
    BuildContext context,
    IconData icon,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    final Color accent = _accent ?? widget.artistAccent ?? theme.primaryColor;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, size: 20, color: _onColor(accent)),
        onPressed: onTap,
        padding: EdgeInsets.zero,
      ),
    );
  }

  /// Menú de 3 puntos (estilo playlist): recargar artworks del álbum.
  Future<void> _showAlbumMenu() async {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
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
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                widget.album.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.palette_rounded),
              title: Text(l10n.reloadArtworks),
              onTap: () => Navigator.pop(ctx, 'recalc'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'recalc') {
      // 1) Recalcula el acento de la portada del álbum (borra su entrada de
      //    paleta y re-extrae).
      final url = widget.album.thumbnailUrl;
      final store = context.read<PaletteCacheStore>();
      if (url != null && url.isNotEmpty) {
        await store.invalidate(url);
        _accentFor = null;
        _accent = null;
        await _extractAccent();
      }
      // 2) Borra el acento cacheado de cada pista de la lista.
      if (mounted) {
        for (final t in _tracks ?? const <Track>[]) {
          final tu = t.thumbnailUrl;
          if (tu != null && tu.isNotEmpty) {
            await store.invalidate(tu);
          }
        }
        setState(() {});
      }
      // 3) Re-lee el tracklist de InnerTube: la portada del header (que
      //    propaga a todas las filas) vuelve con la imagen vigente.
      await _reload();
    }
  }

  /// Info + botones (título, año, nº de canciones, Play/Shuffle).
  Widget _albumInfo(
    ThemeData theme,
    AppLocalizations l10n,
    Widget Function() buttonRow,
  ) {
    final tracks = _tracks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          Text(
            widget.album.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          if (widget.album.year != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.album.year!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (tracks != null && tracks.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              l10n.songCount(tracks.length),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          buttonRow(),
        ],
      ),
    );
  }
}
