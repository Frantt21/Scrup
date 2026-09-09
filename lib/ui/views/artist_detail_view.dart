import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart';
import '../../services/ytmusic_service.dart' show YtmAlbum, YtMusicResult;
import '../../services/settings_store.dart';
import '../playlist_actions.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
import '../widgets/scrup_toasts.dart';
import '../widgets/track_tile.dart';

/// Readable text over a background of the given color (black/white by luminance).
Color _onColor(Color bg) =>
    bg.computeLuminance() > 0.5 ? Colors.black : Colors.white;

/// Menú contextual de pista COMPARTIDO por canal y álbum/single: favorito
/// + añadir a playlist. Vive a nivel de archivo porque los dos estados
/// (_ArtistDetailViewState y _ArtistAlbumViewState) lo usan.
Future<void> _showTrackMenuShared(
  BuildContext context,
  Track track,
  Offset position,
) async {
  final l10n = AppLocalizations.of(context);
  final isFav = await isTrackFavorite(context, track);
  if (!context.mounted) return;
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    clipBehavior: Clip.antiAlias,
    items: [
      ContextMenuItem(
        value: 'fav',
        icon: isFav
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        label: isFav ? l10n.removeFromFavorites : l10n.addToFavorites,
      ),
      ContextMenuItem(
        value: 'add',
        icon: Icons.playlist_add_rounded,
        label: l10n.addToPlaylist,
      ),
    ],
  );
  if (!context.mounted || action == null) return;
  if (action == 'fav') {
    await toggleTrackFavorite(context, track, current: isFav);
  } else if (action == 'add') {
    await showAddToPlaylistDialog(context, track);
  }
}

/// Desktop theme with the artist/album accent as PRIMARY (same approach as
/// the playlist detail): FilledButtons and tints pick the extracted accent
/// instead of the global theme primary.
ThemeData _themeWithAccent(ThemeData base, Color accent) {
  final onPrimary =
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
      ? Colors.white
      : Colors.black;
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      onPrimary: onPrimary,
    ),
  );
}

/// Floating glass panel IDENTICAL to the desktop playlist detail: same margin
/// (12 + player clearance below), radius 18, shadow and translucent
/// background tinted with the accent (lerp 0.30).
Widget _desktopPanel({
  required ThemeData theme,
  required Color? accent,
  required Widget child,
}) {
  final bg = accent == null
      ? theme.colorScheme.surfaceContainerHighest
      : Color.lerp(theme.colorScheme.surfaceContainerHighest, accent, 0.30)!;
  return Container(
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
          color: bg.withValues(alpha: 0.72),
        ),
        child: Material(color: Colors.transparent, child: child),
      ),
    ),
  );
}

/// Artist detail (Android/desktop): data from the InnerTube channel page (top songs + albums) with its own 24h cache.
///
/// Header with PLAYLIST DETAIL style and FULL ARTWORK: the channel image spans the full width (edge-to-edge, behind the status bar) with a gradient that blends into the background color — the same look as the playlist detail in its default style. Buttons use the accent EXTRACTED from the channel image (not the global theme primary). Scrolling shows the artist name in the collapsed appbar. It is mounted INSIDE the shell (nav + miniplayer present).
class ArtistDetailView extends StatefulWidget {
  const ArtistDetailView({
    super.key,
    required this.artist,
    this.onBack,
    this.onAlbumOpenChanged,
    this.albumOpen = false,
  });

  /// Mirror of the shell's open-album flag: when the shell flips it to
  /// false (back button / back gesture), this widget closes its internal
  /// album state via didUpdateWidget.
  final bool albumOpen;

  /// Artist derived from the search: channel + name (no avatar: the real face arrives with the detail).
  final YtmArtist artist;

  /// Returns to the search. On mobile it is provided by AppShell (screen mounted in the shell); if null, it pops the Navigator (desktop).
  final VoidCallback? onBack;

  /// Notifies the shell when an album/single opens/closes inside this
  /// screen, so the Android back gesture returns to the CHANNEL first.
  final ValueChanged<bool>? onAlbumOpenChanged;

  @override
  State<ArtistDetailView> createState() => _ArtistDetailViewState();
}

class _ArtistDetailViewState extends State<ArtistDetailView> {
  YtmArtistDetail? _detail;
  bool _loading = true;
  String? _error;

  /// true cuando el scroll pasó el header del canal: el nombre aparece
  /// entre los botones del header flotante.
  bool _showArtistTitle = false;

  /// Acento extraído de la imagen del canal (mismo camino que el detalle de playlist: PaletteCacheStore + ArtworkPaletteService). Pinta los botones y tiñe el fondo (lerp 0.30, igual que el playlist completo).
  Color? _accent;
  String? _accentFor;

  /// Álbum/single abierto: se muestra EMBEBIDO (en vez del contenido del artista, sin push de ruta) — nav + miniplayer visibles.
  YtmAlbum? _openedAlbum;

  @override
  void didUpdateWidget(covariant ArtistDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // El shell cerró el álbum (botón atrás de la titlebar en desktop o back
    // de Android): limpia el estado interno. Antes solo se togglaba el flag
    // del shell y el álbum seguía abierto → el botón "no hacía nada".
    if (!widget.albumOpen && oldWidget.albumOpen && _openedAlbum != null) {
      setState(() => _openedAlbum = null);
    }
  }

  @override
  void initState() {
    super.initState();
    // Hot cache (same session): paint the FIRST frame with the real data —
    // no placeholder flash for the ~1 frame the async read takes. The
    // accent is also read synchronously from the palette store (no setState
    // here: direct field assignment before the first build).
    final peek = context
        .read<SearchService>()
        .peekArtistDetail(widget.artist.browseId);
    if (peek != null) {
      _detail = peek;
      _loading = false;
      final thumb = peek.thumbnailUrl;
      if (thumb != null && thumb.isNotEmpty) {
        final stored = context.read<PaletteCacheStore>().get(thumb);
        if (stored != null) {
          _accentFor = thumb;
          _accent = stored;
        }
      }
    }
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
      // Los artistas derivados de la búsqueda NO traen avatar (solo canal):
      // la fila de visita se actualiza con la cara real del canal para que
      // la card de "Artistas visitados" del home no quede con placeholder.
      final thumbUrl = detail?.thumbnailUrl ?? widget.artist.thumbnailUrl;
      if (thumbUrl != null && thumbUrl.isNotEmpty) {
        unawaited(
          context.read<AppDatabase>().recordArtistVisit(
            id: widget.artist.browseId,
            name: detail?.name ?? widget.artist.name,
            thumbnailUrl: thumbUrl,
          ),
        );
      }
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

  /// Álbum/single → muestra su tracklist EMBEBIDO (sin Navigator.push): el
  /// spinner vive DENTRO de esa vista mientras trae las pistas.
  Future<void> _openAlbum(YtmAlbum album) async {
    setState(() => _openedAlbum = album);
    widget.onAlbumOpenChanged?.call(true);
  }

  void _back() {
    if (_openedAlbum != null) {
      setState(() => _openedAlbum = null);
      widget.onAlbumOpenChanged?.call(false);
      return;
    }
    final cb = widget.onBack;
    if (cb != null) {
      cb();
    } else {
      Navigator.of(context).maybePop();
    }
  }

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

    // ── DESKTOP ──
    // MISMO estilo que el detalle de playlist de desktop: panel de cristal
    // flotante con hero (portada 160 + nombre + botones) y lista de tracks
    // debajo. El acento va como PRIMARY del theme (buttons/tints, igual que
    // la playlist usa su ambiente).
    if (Binaries.isDesktop) {
      final dtheme = _accent != null
          ? _themeWithAccent(theme, _accent!)
          : theme;
      final onAccent = _onColor(_accent ?? theme.colorScheme.primary);
      final tracks = detail?.tracks ?? const <YtMusicResult>[];
      return _desktopPanel(
        theme: theme,
        accent: _accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 24, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Portada 160 con radio 16 (idéntico al hero de playlist).
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 160,
                      height: 160,
                      child: (detail?.thumbnailUrl?.isNotEmpty ?? false)
                          ? CoverImage(
                              source: detail!.thumbnailUrl,
                              fit: BoxFit.cover,
                              cacheWidth: 400,
                              fallback: ColoredBox(
                                color: theme.colorScheme.surfaceContainerHigh,
                                child: Icon(
                                  Icons.person_rounded,
                                  size: 56,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ColoredBox(
                              color: theme.colorScheme.surfaceContainerHigh,
                              child: Icon(
                                Icons.person_rounded,
                                size: 56,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: dtheme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                        if (detail?.audienceText != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            detail!.audienceText!,
                            style: dtheme.textTheme.bodyMedium?.copyWith(
                              color: dtheme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  (loading || tracks.isEmpty) ? null : _playAll,
                              style: FilledButton.styleFrom(
                                disabledBackgroundColor: _accent,
                                disabledForegroundColor: onAccent.withValues(
                                  alpha: 0.6,
                                ),
                                minimumSize: const Size(0, 44),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(l10n.play),
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
              // UN SOLO scroll vertical (antes la lista era Expanded: las
              // secciones de discografía quedaban fuera y sin scroll):
              // Popular + Álbumes + Singles desplazan juntos.
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : (detail == null || (_error != null && tracks.isEmpty))
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_off_rounded,
                            size: 48,
                            color: dtheme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(l10n.artistDetailEmpty),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _load,
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Popular: encogible (el scroll vive fuera).
                          ...[
                            for (var i = 0; i < tracks.length; i++)
                              () {
                                final r = tracks[i];
                                final track = r.toTrack();
                                return GestureDetector(
                                  onSecondaryTapUp: (d) => unawaited(
                                    _showTrackMenuShared(
                                      context,
                                      track,
                                      d.globalPosition,
                                    ),
                                  ),
                                  child: TrackTile(
                                    track: track,
                                    subtitleSuffix: r.playCountText,
                                    onPlay: () => _playTrack(track, i),
                                    onAddToPlaylist: () =>
                                        showAddToPlaylistDialog(context, track),
                                  ),
                                );
                              }(),
                          ],
                          // Discografía: MISMAS filas horizontales que la
                          // vista móvil (los ListViews horizontales
                          // internos mantienen SU propio scroll lateral).
                          ..._albumSections(detail),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    }

    // ── MÓVIL ──
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (n) {
              final visible = n.metrics.pixels >
                  (expandedH - 90).clamp(0.0, double.infinity);
              if (visible != _showArtistTitle) {
                setState(() => _showArtistTitle = visible);
              }
              return false;
            },
            child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── Header FULL ARTWORK (como la playlist detail) ──────
              // SIN pin: el header se va entero al scrollear y nunca se
              // genera una appbar colapsada (el back flotante es un overlay
              // externo al scroll, igual que la playlist detail).
              SliverAppBar(
                expandedHeight: expandedH,
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
                      return GestureDetector(
                        onSecondaryTapUp: (d) =>
                            unawaited(_showTrackMenuShared(context, track, d.globalPosition)),
                        child: TrackTile(
                          track: track,
                          // Reproducciones de la canción ("1.2M plays").
                          subtitleSuffix: r.playCountText,
                          onPlay: () => _playTrack(track, i),
                          onAddToPlaylist: () =>
                              showAddToPlaylistDialog(context, track),
                        ),
                      );
                    },
                  ),
                  // ── Álbumes y SINGLES: una fila horizontal por tipo ──
                  ..._albumSections(
                    detail,
                  ).map((w) => SliverToBoxAdapter(child: w)),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 24),
                  ),
                ],
              ],
            ),
            ),
            // Header flotante SIEMPRE visible (overlay externo al scroll,
            // como la playlist detail): back al ACENTO + nombre del canal
            // cuando el hero salió de pantalla.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      _floatingCircleBtn(context),
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: _showArtistTitle ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      // Simetría con el back (40dp invisible).
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
    );
  }

  /// Secciones horizontales de discografía: Álbumes y Singles separados
  /// (el subtítulo de la card del canal marca el tipo de lanzamiento).
  /// Devuelve WIDGETS normales (servibles en Column de desktop); el llamado
  /// móvil los envuelve en [SliverToBoxAdapter].
  List<Widget> _albumSections(YtmArtistDetail detail) {
    final albums = [
      for (final a in detail.albums)
        if (!a.isSingle) a,
    ];
    final singles = [
      for (final a in detail.albums)
        if (a.isSingle) a,
    ];
    if (albums.isEmpty && singles.isEmpty) return const [];
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget section(String title, List<YtmAlbum> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(
              // Portada 140 + título (1 línea) + año.
              height: 186,
              // DragScroll: en desktop el ratón NO tiene gesto de arrastre
              // sobre un ListView (solo rueda); con esto arrastrar con el
              // botón presionado desliza la fila (en móvil queda igual).
              child: _DragScroll(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final album = items[i];
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
        );
    return [
      if (albums.isNotEmpty) section(l10n.artistAlbums, albums),
      if (singles.isNotEmpty) section(l10n.artistSingles, singles),
    ];
  }

  Widget _floatingCircleBtn(BuildContext context) {
    final theme = Theme.of(context);
    // MISMO estilo que la playlist detail (y el screen del álbum): círculo
    // 40×40 al ACENTO del canal con icono contrastado.
    final Color accent = _accent ?? theme.colorScheme.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          Icons.arrow_back_rounded,
          size: 20,
          color: _onColor(accent),
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
}

/// Tracklist de un álbum/single con el mismo estilo que el detalle de playlist en modo "acento plano" (flat): fondo del acento extraído de la propia portada del álbum (fallback al artista), portada 1:1 centrada, título y botones Play/Shuffle. Vista embebida (sin push): el spinner vive aquí, nunca en la card.
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

  /// Estilo del header (compartido con la playlist detail): false = portada
  /// 1:1 sobre acento plano (por defecto en álbumes), true = portada
  /// full-bleed con degradado. Se persiste en SettingsStore.
  bool _fullBleed = false;

  /// true cuando el scroll pasó el header: el título aparece entre los
  /// botones del header flotante.
  bool _showScrollTitle = false;

  @override
  void initState() {
    super.initState();
    // Lecturas SÍNCRONAS antes del primer frame: sin flash flat ↔ full-bleed
    // ni acento por defecto (el valor async corregía ~1 frame después).
    _fullBleed =
        context.read<SettingsStore>().flatPlaylistHeaderCache ?? false;
    final url = widget.album.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      _accent = context.read<PaletteCacheStore>().get(url);
    }
    unawaited(_load());
    unawaited(_extractAccent());
  }

  /// Alterna full-bleed ↔ acento plano y persiste (mismo setting que la
  /// playlist detail: ambos estilos viajan juntos).
  void _toggleHeaderStyle() {
    setState(() => _fullBleed = !_fullBleed);
    unawaited(
      context.read<SettingsStore>().saveFlatPlaylistHeader(_fullBleed),
    );
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
    // Fondo full-bleed (estilo playlist por defecto): lerp 0.30.
    final Color bleedColor = Color.lerp(
          theme.colorScheme.surfaceContainerHighest,
          accent,
          0.30,
        ) ??
        theme.colorScheme.surface;
    final bool fullBleed = _fullBleed;
    final Color bgColor = fullBleed ? bleedColor : flatColor;
    final double expandedH = MediaQuery.sizeOf(context).width * (fullBleed ? 1.0 : 0.95);
    // Umbral del título de scroll: justo antes de que el hero salga.
    final double titleThreshold = (expandedH - 90).clamp(0.0, double.infinity);

    // ── DESKTOP ──
    // Panel de cristal IDENTICO al detalle de playlist de desktop: hero con
    // portada 160 + título + año + nº de canciones + Play/Shuffle (botones
    // del MISMO estilo que la playlist) y tracklist debajo.
    if (Binaries.isDesktop) {
      final dtheme = _themeWithAccent(theme, accent);
      return _desktopPanel(
        theme: theme,
        accent: accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 24, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 160,
                      height: 160,
                      child: (widget.album.thumbnailUrl?.isNotEmpty ?? false)
                          ? CoverImage(
                              source: widget.album.thumbnailUrl,
                              fit: BoxFit.cover,
                              cacheWidth: 400,
                              fallback: ColoredBox(
                                color: theme.colorScheme.surfaceContainerHigh,
                                child: const Icon(
                                  Icons.album_rounded,
                                  size: 56,
                                ),
                              ),
                            )
                          : ColoredBox(
                              color: theme.colorScheme.surfaceContainerHigh,
                              child: const Icon(
                                Icons.album_rounded,
                                size: 56,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.album.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: dtheme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                        if (widget.album.year != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            widget.album.year!,
                            style: dtheme.textTheme.bodyMedium?.copyWith(
                              color: dtheme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        // Placeholder '—' mientras llega el tracklist: sin
                        // flash 0 canciones → real.
                        Text(
                          tracks == null
                              ? '—'
                              : l10n.songCount(tracks.length),
                          style: dtheme.textTheme.bodySmall?.copyWith(
                            color: dtheme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  (tracks == null || tracks.isEmpty)
                                  ? null
                                  : _playAll,
                              // Colores fijos en disabled: sin flash
                              // desactivado → activo al entrar.
                              style: FilledButton.styleFrom(
                                disabledBackgroundColor: accent,
                                disabledForegroundColor: _onColor(accent)
                                    .withValues(alpha: 0.6),
                                minimumSize: const Size(0, 44),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(l10n.play),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed:
                                  (tracks == null || tracks.isEmpty)
                                  ? null
                                  : _playShuffled,
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: dtheme.colorScheme.primary,
                                disabledBackgroundColor: Colors.white,
                                disabledForegroundColor: dtheme
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.6),
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
                ],
              ),
            ),
            Expanded(
              // Sin spinner de 1 frame: espacio en blanco y swap silencioso.
              child: tracks == null
                  ? const SizedBox.expand()
                  : tracks.isEmpty
                  ? Center(child: Text(l10n.searchNoResults))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final track = tracks[i];
                        return GestureDetector(
                          onSecondaryTapUp: (d) =>
                              unawaited(_showTrackMenuShared(context, track, d.globalPosition)),
                          child: TrackTile(
                            track: track,
                            onPlay: () => unawaited(
                              context.read<PlayerService>().playQueue(
                                tracks,
                                startIndex: i,
                              ),
                            ),
                            onAddToPlaylist: () =>
                                showAddToPlaylistDialog(context, track),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    }

    Widget buttonRow() => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          // Deshabilitado hasta tener pistas, pero con los MISMOS colores
          // fijos: el estilo M3 disabled (gris pálido) mostraba un flash
          // "desactivado → activo" al cargar el tracklist.
          onPressed: (tracks == null || tracks.isEmpty) ? null : _playAll,
          style: FilledButton.styleFrom(
            disabledBackgroundColor: accent,
            disabledForegroundColor: _onColor(accent).withValues(alpha: 0.6),
            backgroundColor: accent,
            foregroundColor: _onColor(accent),
            minimumSize: const Size(0, 44),
          ),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.play),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: (tracks == null || tracks.isEmpty) ? null : _playShuffled,
          style: FilledButton.styleFrom(
            disabledBackgroundColor: accent,
            disabledForegroundColor: _onColor(accent).withValues(alpha: 0.6),
            backgroundColor: accent,
            foregroundColor: _onColor(accent),
            minimumSize: const Size(0, 44),
          ),
          icon: const Icon(Icons.shuffle_rounded),
          label: Text(l10n.shuffle),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: bgColor,
      // MISMO estilo que la playlist detail móvil en modo "acento plano":
      // SliverAppBar SIN pin (el hero se va entero al scrollear — nunca hay
      // un segundo header), portada 1:1 alineada al tope bajo 110dp y los
      // controles flotantes como overlay EXTERNO al scroll.
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (n) {
              final visible = n.metrics.pixels > titleThreshold;
              if (visible != _showScrollTitle) {
                setState(() => _showScrollTitle = visible);
              }
              return false;
            },
            child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── Header: SOLO portada (idéntico al flat de playlist) ──
              SliverAppBar(
                expandedHeight: expandedH,
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
                  background: fullBleed
                      // Estilo "portada completa": imagen a TODO EL ALTO con
                      // degradado que funde al fondo (mismos stops que la
                      // playlist full-bleed).
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            if (widget.album.thumbnailUrl?.isNotEmpty ?? false)
                              CoverImage(
                                source: widget.album.thumbnailUrl,
                                fit: BoxFit.cover,
                                cacheWidth: 1200,
                                fallback: ColoredBox(color: bgColor),
                              )
                            else
                              ColoredBox(color: bgColor),
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
                        )
                      // Estilo "acento plano": portada 1:1 centrada bajo
                      // los controles (idéntico al flat de playlist).
                      : Stack(
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
                const SliverFillRemaining(child: SizedBox.shrink())
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
                      return GestureDetector(
                        onSecondaryTapUp: (d) =>
                            unawaited(_showTrackMenuShared(context, track, d.globalPosition)),
                        child: TrackTile(
                          track: track,
                          onPlay: () => unawaited(
                            context.read<PlayerService>().playQueue(
                              tracks,
                              startIndex: i,
                            ),
                          ),
                          onAddToPlaylist: () =>
                              showAddToPlaylistDialog(context, track),
                        ),
                      );
                    },
                  ),
                ),
            ],
            ),
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
                    // Título del álbum SOLO cuando el hero salió de pantalla.
                    Expanded(
                      child: AnimatedOpacity(
                        opacity: _showScrollTitle ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Text(
                          widget.album.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
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

  /// Menú de 3 puntos (estilo playlist): recargar artworks, cambiar el
  /// estilo del header y — SOLO en álbumes — crear una playlist con el
  /// tracklist completo.
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
            ListTile(
              leading: Icon(
                _fullBleed ? Icons.grid_view_rounded : Icons.photo_rounded,
              ),
              title: Text(l10n.playlistCoverStyle),
              subtitle: Text(
                _fullBleed
                    ? l10n.playlistCoverStyleFull
                    : l10n.playlistCoverStyleFlat,
              ),
              trailing: Icon(
                _fullBleed ? Icons.check_rounded : Icons.chevron_right_rounded,
              ),
              onTap: () => Navigator.pop(ctx, 'style'),
            ),
            // SOLO álbumes (no singles): crea una playlist local con todo
            // el tracklist del álbum.
            if (!widget.album.isSingle)
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: Text(l10n.createPlaylistFromAlbum),
                onTap: () => Navigator.pop(ctx, 'create_playlist'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'style') {
      _toggleHeaderStyle();
      return;
    }
    if (action == 'create_playlist') {
      await _createPlaylistFromAlbum();
      return;
    }
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

  /// Crea una playlist local con el tracklist del álbum (SOLO álbumes).
  /// Portada por defecto: la del álbum (el propio addToPlaylist la aplica
  /// con la primera pista, pero aquí la fijamos de una vez).
  Future<void> _createPlaylistFromAlbum() async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    final db = context.read<AppDatabase>();
    final name = widget.album.title.trim();
    final int id;
    try {
      id = await db.createPlaylist(name);
    } catch (_) {
      if (!mounted) return;
      showScrupToast(
        AppLocalizations.of(context).cantCreatePlaylist,
        kind: ScrupToastKind.error,
      );
      return;
    }
    for (final track in tracks) {
      try {
        // Dedupe interno: si ya estaba, no la duplica.
        await db.addToPlaylist(id, track);
      } catch (_) {}
    }
    // Portada del álbum (si addToPlaylist ya puso una, esta la iguala).
    final cover = widget.album.thumbnailUrl;
    if (cover != null && cover.isNotEmpty) {
      try {
        await db.setPlaylistCover(id, cover);
      } catch (_) {}
    }
    if (!mounted) return;
    showScrupToast(
      AppLocalizations.of(context).playlistCreated(name),
      kind: ScrupToastKind.success,
    );
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
          ] else
            // Placeholder del MISMO estilo mientras llega el tracklist: sin
            // flash vacío → real.
            const SizedBox(height: 18),
          const SizedBox(height: 16),
          buttonRow(),
        ],
      ),
    );
  }
}

/// Scroll por ARRASTRE del ratón (desktop): envuelve un scrollable
/// horizontal y lo desliza con el botón presionado (los ListViews
/// horizontales solo responden a la rueda). En móvil no interfiere: el
/// drag de ratón no ocurre y el tacto usa el gesto nativo.
class _DragScroll extends StatefulWidget {
  const _DragScroll({required this.child});

  final Widget child;

  @override
  State<_DragScroll> createState() => _DragScrollState();
}

class _DragScrollState extends State<_DragScroll> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _dragging
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.basic,
      child: Listener(
        onPointerDown: (d) {
          if (d.buttons & kPrimaryButton == 0) return;
          _dragging = true;
        },
        onPointerMove: (d) {
          if (!_dragging) return;
          // Scroll físico del viewport padre: el Listener envuelve DIRECTO
          // al viewport, así que la posición apunta a su Scrollable. Antes
          // este widget creaba su propio controller que NUNCA se adjuntaba
          // a la lista (hasClients siempre false) y el drag era un no-op.
          final state = Scrollable.maybeOf(context, axis: Axis.horizontal);
          final pos = state?.position;
          if (pos == null || !pos.hasContentDimensions) return;
          pos.jumpTo((pos.pixels - d.delta.dx).clamp(
            pos.minScrollExtent,
            pos.maxScrollExtent,
          ));
        },
        onPointerUp: (_) => _dragging = false,
        onPointerCancel: (_) => _dragging = false,
        child: widget.child,
      ),
    );
  }
}
