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

/// Detalle de artista (Android/desktop): datos de la página de canal de
/// InnerTube (top canciones + álbumes) con caché propio de 24h.
///
/// Header estilo DETALLE DE PLAYLIST (móvil): portada del canal full-bleed
/// con degradado que funde al color de fondo, degradado EXTRAÍDO de la
/// propia imagen (palette service, igual que las playlists) y, al
/// scrollear, la appbar colapsada muestra el nombre del artista con el
/// blur/zoom del FlexibleSpaceBar de por medio.
class ArtistDetailView extends StatefulWidget {
  const ArtistDetailView({super.key, required this.artist});

  /// Artista derivado de la búsqueda: canal + nombre (sin avatar: la cara
  /// real llega con el detalle).
  final YtmArtist artist;

  @override
  State<ArtistDetailView> createState() => _ArtistDetailViewState();
}

class _ArtistDetailViewState extends State<ArtistDetailView> {
  YtmArtistDetail? _detail;
  bool _loading = true;
  String? _error;
  int? _openedAlbumIndex;

  /// Nombre visible en la appbar colapsada (true al pasar el umbral del
  /// header expandido).
  bool _showPinnedTitle = false;

  /// Color EXTRAÍDO de la imagen del canal (palette service, igual que el
  /// detalle de playlist): tiñe el fondo de todo el screen.
  Color? _ambientColor;
  String? _ambientFor;

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
      if (detail == null) {
        setState(() {
          _loading = false;
          _error = 'no-data';
        });
        return;
      }
      setState(() {
        _detail = detail;
        _loading = false;
      });
      _maybeExtractAmbient(detail.thumbnailUrl);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'network';
      });
    }
  }

  /// Extrae el color ambiente del avatar/portada del canal (con caché en el
  /// PaletteCacheStore, mismo camino que el detalle de playlist).
  Future<void> _maybeExtractAmbient(String? thumb) async {
    if (thumb == null || thumb.isEmpty || thumb == _ambientFor) return;
    _ambientFor = thumb;
    final stored = context.read<PaletteCacheStore>().get(thumb);
    if (stored != null) {
      setState(() => _ambientColor = stored);
      return;
    }
    Color? color;
    try {
      final trio = await ArtworkPaletteService.trioFor(
        thumb,
        context.read<PaletteCacheStore>(),
        artworkCache: context.read<ArtworkCacheService>(),
      );
      color = trio.isEmpty
          ? null
          : (ArtworkPaletteService.accentFromTrio(trio) ?? trio.first);
    } catch (_) {
      color = null;
    }
    if (!mounted) return;
    setState(() => _ambientColor = color);
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

  /// Álbum → abre su tracklist (fetch + pantalla aparte).
  Future<void> _openAlbum(int index) async {
    final detail = _detail;
    if (detail == null || index >= detail.albums.length) return;
    final album = detail.albums[index];
    setState(() => _openedAlbumIndex = index);
    try {
      final tracks = await context
          .read<SearchService>()
          .fetchAlbumTracks(album.playlistId);
      if (!mounted) return;
      if (tracks.isEmpty) {
        setState(() => _openedAlbumIndex = null);
        return;
      }
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => ArtistAlbumView(album: album, tracks: tracks),
        ),
      );
      if (mounted) setState(() => _openedAlbumIndex = null);
    } catch (_) {
      if (mounted) setState(() => _openedAlbumIndex = null);
    }
  }

  /// Umbral (offset de scroll) a partir del cual la appbar colapsada muestra
  /// el nombre: justo antes de que el header expandido salga de pantalla.
  double _titleThreshold(double expandedHeight) =>
      (expandedHeight - 90).clamp(0.0, double.infinity);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final detail = _detail;

    // Fondo con el color EXTRAÍDO de la imagen (mismo lerp 0.30 que el
    // detalle de playlist móvil): sin costura entre header y contenido.
    final Color bgColor = _ambientColor == null
        ? theme.colorScheme.surface
        : (Color.lerp(
                theme.colorScheme.surfaceContainerHighest,
                _ambientColor,
                0.30,
              ) ??
              theme.colorScheme.surface);

    final bool loading = _loading && detail == null;
    // Alto del header expandido: casi cuadrado, como la portada del detalle
    // de playlist (width*0.95) — el avatar del canal a PANTALLA COMPLETA.
    final double expandedH = MediaQuery.sizeOf(context).width * 0.95;
    final String name = (detail?.name.isNotEmpty ?? false)
        ? detail!.name
        : widget.artist.name;

    return Scaffold(
      backgroundColor: bgColor,
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final visible =
              n.metrics.pixels > _titleThreshold(expandedH);
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
                // ── Header full-bleed estilo playlist ──────────────────
                SliverAppBar(
                  expandedHeight: expandedH,
                  pinned: true,
                  stretch: true,
                  stretchTriggerOffset: 60,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  automaticallyImplyLeading: false,
                  centerTitle: true,
                  // Nombre del artista SOLO cuando el header está colapsado
                  // (transición suave con el blur del zoom de fondo).
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
                    background: _Header(
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
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
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
                          FilledButton.tonal(
                            onPressed: _load,
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
                                loading: _openedAlbumIndex == i,
                                onTap: () => unawaited(_openAlbum(i)),
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
            // Back flotante SIEMPRE visible (sobre el cover y sobre la
            // appbar colapsada), igual que el detalle de playlist.
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
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          Icons.arrow_back_rounded,
          size: 20,
          color: theme.colorScheme.onPrimary,
        ),
        onPressed: () => Navigator.of(context).maybePop(),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Header full-bleed: la imagen del canal a TODO EL ALTO del flexible space
/// (como la portada del detalle de playlist) con degradado inferior que
/// funde al color de fondo. Placeholder con degradado neutro mientras
/// carga.
class _Header extends StatelessWidget {
  const _Header({
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
        // Imagen COMPLETA (sin círculo, sin recorte cuadrado flotante).
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
        // Degradado inferior: funde al color de fondo (sin costura).
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
/// título + año debajo. Muestra spinner al abrir.
class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.loading,
    required this.onTap,
  });

  final YtmAlbum album;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = album.thumbnailUrl;
    const width = 140.0;

    return GestureDetector(
      onTap: loading ? null : onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Portada 1:1 COMPLETA (todo el ancho del card).
            SizedBox(
              width: width,
              height: width,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
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
                  if (loading)
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
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

/// Tracklist de un álbum (pantalla aparte, leída del playlistId con
/// fetchPlaylist y cacheada en el search cache como cualquier búsqueda).
class ArtistAlbumView extends StatelessWidget {
  const ArtistAlbumView({super.key, required this.album, required this.tracks});

  final YtmAlbum album;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(album.title)),
      body: tracks.isEmpty
          ? Center(child: Text(l10n.searchNoResults))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
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
      bottomNavigationBar: tracks.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: () => unawaited(
                    context.read<PlayerService>().playQueue(tracks),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(l10n.playAll),
                ),
              ),
            ),
    );
  }
}
