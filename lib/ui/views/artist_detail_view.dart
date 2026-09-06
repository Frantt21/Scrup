import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart';
import '../playlist_actions.dart';
import '../widgets/cover_image.dart';
import '../widgets/track_tile.dart';

/// Detalle de artista (Android/desktop): datos de la página de canal de
/// InnerTube (top canciones + álbumes + suscriptores) con caché propio de
/// 24h. Entrar de nuevo es instantáneo.
class ArtistDetailView extends StatefulWidget {
  const ArtistDetailView({super.key, required this.artist});

  /// Artista derivado de la búsqueda: canal + nombre + avatar si hay.
  final YtmArtist artist;

  @override
  State<ArtistDetailView> createState() => _ArtistDetailViewState();
}

class _ArtistDetailViewState extends State<ArtistDetailView> {
  YtmArtistDetail? _detail;
  bool _loading = true;
  String? _error;
  int? _openedAlbumIndex;

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
      // Detecta el álbum cuyo tracklist ya está en cola (vuelta del pop).
      final queue = context.read<PlayerService>().queue.value;
      setState(() {
        _detail = detail;
        _loading = false;
        _openedAlbumIndex = _matchingAlbum(detail, queue);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'network';
      });
    }
  }

  /// Índice del álbum cuyo playlistId coincide con la cola activa (si la
  /// cola vino de ese álbum), para restaurar su sección al volver.
  int? _matchingAlbum(YtmArtistDetail detail, List<Track> queue) {
    if (queue.isEmpty || _openedAlbumIndex == null) return _openedAlbumIndex;
    if (_openedAlbumIndex! >= detail.albums.length) return null;
    return _openedAlbumIndex;
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

  /// Álbum → abre su playlist (fetch + sección inline con back-restorable
  /// position via scroll offset save/restore).
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final detail = _detail;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: _Header(detail: detail, artist: widget.artist),
            ),
          ),
          if (_loading)
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
            if (detail.tracks.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.artistTopTracks,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _playAll,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(l10n.playAll),
                      ),
                    ],
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
                  // Reproducciones de la canción ("1.2M plays") tal como
                  // las trae el tab de canciones de InnerTube.
                  subtitleSuffix: r.playCountText,
                  onPlay: () => _playTrack(track, i),
                  onAddToPlaylist: () =>
                      showAddToPlaylistDialog(context, track),
                );
              },
            ),
            if (detail.albums.isNotEmpty)
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
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
                itemCount: detail.albums.length,
                itemBuilder: (context, i) {
                  final album = detail.albums[i];
                  return _AlbumCard(
                    album: album,
                    loading: _openedAlbumIndex == i,
                    onTap: () => unawaited(_openAlbum(i)),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Header con avatar/nombre/suscriptores; usa el detalle si ya llegó y el
/// artist derivado de la búsqueda mientras carga (o si el fetch falla).
class _Header extends StatelessWidget {
  const _Header({required this.detail, required this.artist});

  final YtmArtistDetail? detail;
  final YtmArtist artist;

  /// Métrica del header: la audiencia mensual textual de InnerTube si
  /// existe ("218M monthly audience"), si no los suscriptores formateados.
  String _audienceLabel(
    YtmArtistDetail? detail,
    YtmArtist artist,
    AppLocalizations l10n,
  ) {
    final aud = detail?.audienceText;
    if (aud != null && aud.isNotEmpty) return aud;
    final subs = detail?.subscriberCount ?? artist.subscriberCount;
    if (subs == null || subs <= 0) return '';
    if (subs >= 1000000) {
      return '${(subs / 1000000).toStringAsFixed(subs % 1000000 == 0 ? 0 : 1)}M ${l10n.artistSubscribers}';
    }
    if (subs >= 1000) {
      return '${(subs / 1000).toStringAsFixed(subs % 1000 == 0 ? 0 : 1)}K ${l10n.artistSubscribers}';
    }
    return '$subs ${l10n.artistSubscribers}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final name = (detail?.name.isNotEmpty ?? false)
        ? detail!.name
        : artist.name;
    final thumb = detail?.thumbnailUrl ?? artist.thumbnailUrl;
    final audience = _audienceLabel(detail, artist, l10n);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surfaceContainerHighest,
                theme.colorScheme.surface,
              ],
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipOval(
              child: SizedBox(
                width: 96,
                height: 96,
                child: thumb != null && thumb.isNotEmpty
                    ? CoverImage(
                        source: thumb,
                        width: 96,
                        height: 96,
                        cacheWidth: 192,
                        fit: BoxFit.cover,
                        fallback: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.person_rounded,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person_rounded,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              name,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            if (audience.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                audience,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Card de álbum: portada + título + año. Muestra spinner al abrir.
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
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: thumb != null && thumb.isNotEmpty
                      ? CoverImage(
                          source: thumb,
                          fit: BoxFit.cover,
                          cacheWidth: 300,
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
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
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
