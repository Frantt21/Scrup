import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../playback.dart';
import '../widgets/track_tile.dart';

/// Detalle de una playlist: lista sus canciones con opción de reproducir
/// cualquiera o todas en orden.
class PlaylistDetailView extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailView({super.key, required this.playlist});

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  late final Stream<List<Track>> _tracksStream;
  StreamSubscription<List<Track>>? _sub;
  List<Track> _tracks = const [];

  @override
  void initState() {
    super.initState();
    _tracksStream = context
        .read<AppDatabase>()
        .watchPlaylistTracks(widget.playlist.id);
    _sub = _tracksStream.listen((tracks) {
      if (!mounted) return;
      setState(() => _tracks = tracks);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _playAll() async {
    // Reproduce toda la playlist como cola (auto-advance al terminar).
    await playQueue(context, _tracks);
  }

  Future<void> _removeTrack(Track track) async {
    await context
        .read<AppDatabase>()
        .removeFromPlaylist(widget.playlist.id, track.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          if (_tracks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.playlist_play),
              tooltip: 'Reproducir todas',
              onPressed: _playAll,
            ),
        ],
      ),
      body: _tracks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.music_off,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
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
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
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
    );
  }
}
