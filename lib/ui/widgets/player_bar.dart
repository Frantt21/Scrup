import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/player_service.dart';

/// Barra inferior fija con los controles del reproductor.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key});

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  Track? _track;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _buffering = false;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _subs.addAll([
      player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() => _track = t);
      }),
      player.position.listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
      }),
      player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      }),
      player.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      }),
      player.buffering.listen((b) {
        if (!mounted) return;
        setState(() => _buffering = b);
      }),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTrack = _track != null;
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      elevation: 12,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Barra de progreso
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: progress,
                  onChanged: hasTrack
                      ? (v) {
                          final target = Duration(
                            milliseconds: (v * total.inMilliseconds).round(),
                          );
                          context.read<PlayerService>().seek(target);
                        }
                      : null,
                ),
              ),
              Row(
                children: [
                  // Metadatos
                  Expanded(
                    child: hasTrack
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _track!.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                _track!.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            'Sin reproducción',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  const SizedBox(width: 16),
                  // Tiempo
                  Text(_fmt(_position), style: theme.textTheme.labelSmall),
                  const SizedBox(width: 8),
                  Text(
                    '/ ${total.inMilliseconds > 0 ? _fmt(total) : '--:--'}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Controles
                  if (_buffering)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  else
                    IconButton(
                      iconSize: 36,
                      icon: Icon(
                        _playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                      ),
                      onPressed: hasTrack
                          ? () => context.read<PlayerService>().togglePlayPause()
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
