import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme_controller.dart';

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
    final themeController = context.watch<ThemeController>();
    final accent = themeController.accentColor ?? theme.colorScheme.primary;

    if (track == null) return const SizedBox.shrink();

    final progress = _duration != null && _duration!.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration!.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      clipBehavior: Clip.antiAlias,
      // Mismo acento del player desktop, en PLANO (sin degradado): base
      // translúcida + acento uniforme en todo el fondo del mini-player.
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Stack(
        children: [
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: accent),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, color, _) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: (color ?? accent).withValues(alpha: 0.25),
                  ),
                );
              },
            ),
          ),
          // Efecto de progreso sobre el fondo (estilo forawn_mobile): en vez
          // de una barra en el borde superior, una capa translúcida del acento
          // que crece desde la izquierda con el avance de la reproducción.
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                heightFactor: 1.0,
                widthFactor: progress,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
          ),
          InkWell(
        onTap: widget.onOpenNowPlaying,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    ],
    ),
    );
  }
}
