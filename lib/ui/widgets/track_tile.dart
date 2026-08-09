import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';

/// Fila de una pista (resultados, recientes, playlists).
///
/// - [onPlay]: reproduce la pista al tocar la fila.
/// - [onAddToPlaylist]: muestra un botón "+" para añadir a playlist.
/// - [trailing]: widget extra opcional al final (p. ej. quitar de playlist).
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  final VoidCallback? onAddToPlaylist;
  final Widget? trailing;

  const TrackTile({
    super.key,
    required this.track,
    required this.onPlay,
    this.onAddToPlaylist,
    this.trailing,
  });

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
    final l10n = AppLocalizations.of(context);

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
                    track.artist.isEmpty ? l10n.unknownArtist : track.artist,
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
            // Botón añadir a playlist
            if (onAddToPlaylist != null)
              IconButton(
                icon: Icon(
                  Icons.playlist_add,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onAddToPlaylist,
                tooltip: l10n.addToPlaylist,
              ),
            // Widget extra (quitar, etc.)
            ?trailing,
          ],
        ),
      ),
    );
  }

  Widget _thumbnailFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
