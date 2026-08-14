import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import 'cover_image.dart';
import 'now_playing_bars.dart';

/// Fila de una pista (resultados, recientes, playlists).
///
/// - [onPlay]: reproduce la pista al tocar la fila.
/// - [onAddToPlaylist]: muestra un botón "+" para añadir a playlist.
/// - [trailing]: widget extra opcional al final (p. ej. quitar de playlist).
/// - [isCurrent]/[isPlaying]: si la pista es la que está en el reproductor,
///   el título se pinta en el acento y un ecualizador animado lo indica
///   (moviéndose si suena, quieto si está pausada).
/// - [accentColor]: color del artwork (p. ej. el de la playlist): tintar el
///   texto y los iconos con ese color. Si es oscuro se aclara hacia blanco
///   para mantener la legibilidad sobre el cristal oscuro, conservando el
///   tinte. `null` = colores estándar del tema.
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  final VoidCallback? onAddToPlaylist;
  final Widget? trailing;
  final bool isCurrent;
  final bool isPlaying;
  final Color? accentColor;

  const TrackTile({
    super.key,
    required this.track,
    required this.onPlay,
    this.onAddToPlaylist,
    this.trailing,
    this.isCurrent = false,
    this.isPlaying = false,
    this.accentColor,
  });

  String get _durationText {
    final d = track.duration;
    if (d == null) return '';
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Aclara un acento oscuro hacia blanco para que el texto siga siendo
  /// legible sobre el cristal oscuro, conservando el tinte del artwork
  /// (los acentos extraídos suelen ser `darkVibrant`, pensados para botones
  /// sobre fondo negro, no para texto).
  static Color _readableTint(Color color) {
    final luminance = color.computeLuminance();
    return luminance < 0.35 ? Color.lerp(color, Colors.white, 0.42)! : color;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final accent = accentColor;
    // Tinte legible del artwork para texto/iconos (null = tema estándar).
    final tint = accent == null ? null : _readableTint(accent);
    // La pista en reproducción se resalta: tinte pleno vs. atenuado.
    final titleColor = tint == null
        ? (isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface)
        : (isCurrent ? tint : tint.withValues(alpha: 0.78));
    final subtitleColor = tint == null
        ? theme.colorScheme.onSurfaceVariant
        : tint.withValues(alpha: 0.68);
    final durationColor = tint == null
        ? (isCurrent
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant)
        : tint.withValues(alpha: 0.85);

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
                child: CoverImage(
                  source: track.thumbnailUrl,
                  fit: BoxFit.cover,
                  fallback: _thumbnailFallback(theme, tint: tint),
                ),
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
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist.isEmpty ? l10n.unknownArtist : track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: subtitleColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Indicador de reproducción (ecualizador) + duración
            if (isCurrent) ...[
              const SizedBox(width: 2),
              // Con tinte, el ecualizador usa la variante aclarada (el
              // primary sin aclarar sería oscuro y se perdería en el cristal)
              NowPlayingBars(
                active: isPlaying,
                size: 15,
                color: tint ?? theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
            ],
            // Duración
            if (_durationText.isNotEmpty)
              Text(
                _durationText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: durationColor,
                ),
              ),
            const SizedBox(width: 4),
            // Botón añadir a playlist
            if (onAddToPlaylist != null)
              IconButton(
                icon: Icon(
                  Icons.playlist_add,
                  color:
                      tint?.withValues(alpha: 0.85) ??
                      theme.colorScheme.onSurfaceVariant,
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

  Widget _thumbnailFallback(ThemeData theme, {Color? tint}) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color:
            tint?.withValues(alpha: 0.75) ?? theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
