import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/player_service.dart';
import 'cover_image.dart';

/// Mini-reproductor para móvil: carátula + título + controles esenciales en
/// una barra compacta sobre la NavigationBar inferior. Tocar la zona de la
/// carátula/título abre la pantalla "now playing" (fullscreen).
class MiniPlayer extends StatefulWidget {
  final VoidCallback onOpenNowPlaying;
  final VoidCallback onOpenQueue;

  const MiniPlayer({
    super.key,
    required this.onOpenNowPlaying,
    required this.onOpenQueue,
  });

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  Track? _track;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  Timer? _ticker;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _track = player.currentTrackValue;
    _duration = player.durationValue;
    _subs.addAll([
      player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() => _track = t);
        if (t != null) _ticker ??= _startTicker();
      }),
      player.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      }),
      player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      }),
    ]);
    if (player.currentTrackValue != null) {
      _ticker = _startTicker();
    }
  }

  Timer _startTicker() {
    final player = context.read<PlayerService>();
    return Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final pos = player.positionValue;
      if (pos != _position) setState(() => _position = pos);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();

    if (track == null) return const SizedBox.shrink();

    final progress = _duration != null && _duration!.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration!.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: widget.onOpenNowPlaying,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Barra de progreso fina y táctil.
            LinearProgressIndicator(
              value: progress,
              minHeight: 2.5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CoverImage(
                      source: track.thumbnailUrl,
                      width: 42,
                      height: 42,
                      fallback: Container(
                        width: 42,
                        height: 42,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (track.artist.isNotEmpty)
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    tooltip: _playing ? 'Pausar' : 'Reproducir',
                    onPressed: () => player.togglePlayPause(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    tooltip: 'Siguiente',
                    onPressed: player.next,
                  ),
                  IconButton(
                    icon: const Icon(Icons.queue_music_rounded),
                    tooltip: 'Cola',
                    onPressed: widget.onOpenQueue,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
