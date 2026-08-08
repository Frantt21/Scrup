import 'package:flutter/material.dart';

import '../../core/track.dart';

/// Fila de una pista en los resultados de búsqueda.
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;

  const TrackTile({super.key, required this.track, required this.onPlay});

  String get _durationText {
    final d = track.duration;
    if (d == null) return '';
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onPlay,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 56,
                child: track.thumbnailUrl != null
                    ? Image.network(
                        track.thumbnailUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _thumbnailFallback(theme),
                      )
                    : _thumbnailFallback(theme),
              ),
            ),
            const SizedBox(width: 12),
            // Título y artista
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist.isEmpty ? 'Artista desconocido' : track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Duración
            if (_durationText.isNotEmpty)
              Text(
                _durationText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 4),
            // Botón reproducir
            IconButton(
              icon: Icon(Icons.play_circle_outline,
                  color: theme.colorScheme.primary),
              onPressed: onPlay,
              tooltip: 'Reproducir',
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnailFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
