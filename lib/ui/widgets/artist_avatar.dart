import 'package:flutter/material.dart';

import '../../core/track.dart';
import 'cover_image.dart';

/// Single channel-avatar resolver for the whole app.
///
/// Everything that paints an artist face goes through [artistAvatarUrl]:
/// search rows, home visited-artist cards, the now-playing panel and the
/// recap. It normalizes to a SQUARE high-res crop when the URL is a
/// googleusercontent one (the variants without `-p` are NOT square and
/// return a different framing), so every surface paints the same face.
class ArtistAvatar {
  ArtistAvatar._();

  /// Best URL for painting a channel avatar from a raw thumbnail.
  /// Falls back to the input when it is not a Google-hosted URL. Uses the
  /// SQUARE crop helper (preserves Google's `-p` framing params — the bare
  /// `=w1200-h1200` rewrite returns a different, non-square image).
  static String? hiRes(String? url) {
    if (url == null || url.isEmpty) return null;
    final square = Track.squareHiResThumbnail(url);
    return square ?? url;
  }

  /// Size (logical px) the avatar is painted at; the network request asks
  /// for ~2.5x so it stays sharp on high-DPR phones without over-fetching.
  static int cacheWidthFor(double side) => (side * 2.5).round();
}

/// Reusable artist-face widget: square-rounded like the covers, with the
/// person placeholder while the URL is missing or the image fails.
class ArtistAvatarImage extends StatelessWidget {
  const ArtistAvatarImage({
    super.key,
    required this.url,
    this.side = 48,
    this.radius = 14,
    this.circle = false,
  });

  /// Raw avatar URL (already-normalized URLs pass through fine).
  final String? url;

  /// Painted side (logical px).
  final double side;

  /// Corner radius when [circle] is false.
  final double radius;

  /// Circular clip (classic avatar) instead of rounded square.
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final src = ArtistAvatar.hiRes(url);
    final shape = circle
        ? BorderRadius.circular(side / 2)
        : BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: SizedBox(
        width: side,
        height: side,
        child: src != null
            ? CoverImage(
                source: src,
                width: side,
                height: side,
                cacheWidth: ArtistAvatar.cacheWidthFor(side),
                fit: BoxFit.cover,
                fallback: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.person_rounded,
                    size: side * 0.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person_rounded,
                  size: side * 0.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}
