import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../playback.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;
import '../widgets/track_tile.dart';

/// Detalle de una playlist renderizado EN EL MISMO espacio que el grid (sin
/// abrir rutas): cabecera con portada y acciones (cambiar portada, reproducir
/// todas) y la lista de canciones con reproducción individual o en cola.
class PlaylistDetailView extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onBack;

  const PlaylistDetailView({
    super.key,
    required this.playlist,
    required this.onBack,
  });

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  late final Stream<List<Track>> _tracksStream;
  late final Stream<Playlist?> _playlistStream;
  StreamSubscription<List<Track>>? _tracksSub;
  StreamSubscription<Playlist?>? _playlistSub;
  List<Track> _tracks = const [];

  /// Playlist en vivo (la portada puede cambiar desde este mismo detalle).
  Playlist? _playlist;

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
    });
    _tracksStream = db.watchPlaylistTracks(widget.playlist.id);
    _tracksSub = _tracksStream.listen((tracks) {
      if (!mounted) return;
      setState(() => _tracks = tracks);
    });
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    _playlistSub?.cancel();
    super.dispose();
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    // Reproduce toda la playlist como cola (auto-advance al terminar).
    await playQueue(context, _tracks);
  }

  Future<void> _removeTrack(Track track) async {
    await context.read<AppDatabase>().removeFromPlaylist(
      widget.playlist.id,
      track.id,
    );
  }

  /// Selector de portada: elegir el artwork de una de las canciones de la
  /// playlist (o quitar la portada actual).
  Future<void> _pickCover() async {
    final db = context.read<AppDatabase>();
    final choice = await showModalBottomSheet<({String? url, bool remove})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Portada de la playlist',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            if (_tracks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'Añade canciones para poder usar su portada como la de la '
                  'playlist.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final track in _tracks.take(12))
              ListTile(
                dense: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: track.thumbnailUrl != null
                        ? Image.network(
                            track.thumbnailUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                _artworkFallback(Theme.of(ctx)),
                          )
                        : _artworkFallback(Theme.of(ctx)),
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
                onTap: () => Navigator.pop(ctx, (
                  url: track.thumbnailUrl,
                  remove: false,
                )),
              ),
            if (_playlist?.coverUrl != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_outline),
                title: const Text('Quitar portada'),
                onTap: () => Navigator.pop(ctx, (url: null, remove: true)),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice.remove) {
      await db.setPlaylistCover(widget.playlist.id, null);
    } else {
      await db.setPlaylistCover(widget.playlist.id, choice.url);
    }
  }

  Widget _artworkFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = _playlist ?? widget.playlist;
    final count = _tracks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cabecera: volver + portada + nombre + acciones
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Volver a playlists',
                onPressed: widget.onBack,
              ),
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: _coverArt(theme, playlist.coverUrl),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count ${count == 1 ? 'canción' : 'canciones'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.photo_library_outlined),
                tooltip: 'Portada de la playlist',
                onPressed: _pickCover,
              ),
              if (_tracks.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.playlist_play),
                  tooltip: 'Reproducir todas',
                  onPressed: _playAll,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _tracks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.music_off,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Playlist vacía',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Añade canciones desde la búsqueda',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  // El player flotante cubre la parte inferior: dejar espacio
                  // para que la última canción quede accesible.
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    kPlayerOverlayInset,
                  ),
                  itemCount: _tracks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final track = _tracks[i];
                    return TrackTile(
                      track: track,
                      onPlay: () => playTrack(context, track),
                      trailing: IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: 'Quitar de la playlist',
                        onPressed: () => _removeTrack(track),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _coverArt(ThemeData theme, String? url) {
    if (url == null) {
      return Container(
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
          Icons.queue_music,
          size: 24,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: 200,
      errorBuilder: (_, _, _) => Container(
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
          Icons.queue_music,
          size: 24,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
