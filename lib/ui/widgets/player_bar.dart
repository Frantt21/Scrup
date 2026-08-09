import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';

/// Barra inferior fija con los controles del reproductor: artwork, título,
/// progreso, loader y controles (shuffle, anterior, play/pausa, siguiente,
/// repeat y radio).
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final cache = context.read<AudioCacheService>();
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                          player.seek(target);
                        }
                      : null,
                ),
              ),
              Row(
                children: [
                  // Artwork
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: hasTrack && _track!.thumbnailUrl != null
                          ? Image.network(
                              _track!.thumbnailUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _artworkFallback(theme),
                            )
                          : _artworkFallback(theme),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Metadatos
                  Expanded(
                    child: hasTrack
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ValueListenableBuilder<double?>(
                                valueListenable: cache.progress,
                                builder: (context, downloadPct, _) {
                                  return ValueListenableBuilder<String?>(
                                    valueListenable: player.preparingTrackId,
                                    builder: (context, preparingId, _) {
                                      // Solo mostrar el % si la descarga es
                                      // de la pista que se está preparando
                                      // (si el usuario saltó de pista, la
                                      // descarga sigue en segundo plano).
                                      final downloadingCurrent =
                                          cache.downloadingId.value ==
                                              preparingId;
                                      final String label;
                                      if (downloadPct != null &&
                                          downloadPct < 1 &&
                                          downloadingCurrent) {
                                        label = 'Descargando… '
                                            '${(downloadPct * 100).round()}%';
                                      } else if (preparingId != null) {
                                        label = 'Preparando…';
                                      } else {
                                        label = _track!.title;
                                      }
                                      return Text(
                                        label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall,
                                      );
                                    },
                                  );
                                },
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
                  const SizedBox(width: 8),
                  // Controles
                  _buildControls(context, theme, player, hasTrack),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    ThemeData theme,
    PlayerService player,
    bool hasTrack,
  ) {
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;

    return ValueListenableBuilder<String?>(
      valueListenable: player.preparingTrackId,
      builder: (context, preparingId, _) {
        final preparing = preparingId != null;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Shuffle
            ValueListenableBuilder<bool>(
              valueListenable: player.shuffle,
              builder: (context, on, _) => IconButton(
                icon: Icon(Icons.shuffle, size: 20),
                color: on ? primary : muted,
                tooltip: on ? 'Aleatorio: activo' : 'Aleatorio',
                onPressed: player.toggleShuffle,
              ),
            ),
            // Anterior
            IconButton(
              icon: const Icon(Icons.skip_previous),
              color: muted,
              tooltip: 'Anterior',
              onPressed: hasTrack ? player.previous : null,
            ),
            // Play / Pausa (o loader)
            if (preparing || _buffering)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else
              IconButton(
                iconSize: 40,
                icon: Icon(
                  _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: primary,
                ),
                tooltip: _playing ? 'Pausar' : 'Reproducir',
                onPressed: hasTrack ? player.togglePlayPause : null,
              ),
            // Siguiente
            IconButton(
              icon: const Icon(Icons.skip_next),
              color: muted,
              tooltip: 'Siguiente',
              onPressed: hasTrack ? player.next : null,
            ),
            // Repeat (cicla off → all → one)
            ValueListenableBuilder<LoopMode>(
              valueListenable: player.repeatMode,
              builder: (context, mode, _) {
                final active = mode != LoopMode.off;
                return IconButton(
                  icon: Icon(
                    mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                    size: 20,
                  ),
                  color: active ? primary : muted,
                  tooltip: switch (mode) {
                    LoopMode.off => 'Repetir: desactivado',
                    LoopMode.all => 'Repetir: toda la cola',
                    LoopMode.one => 'Repetir: canción actual',
                  },
                  onPressed: player.toggleRepeat,
                );
              },
            ),
            // Radio (mismo artista al terminar)
            ValueListenableBuilder<bool>(
              valueListenable: player.radio,
              builder: (context, on, _) => IconButton(
                icon: Icon(
                  Icons.radio,
                  size: 20,
                  color: on ? primary : muted,
                ),
                tooltip: on ? 'Radio: activa' : 'Radio: inactiva',
                onPressed: player.toggleRadio,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _artworkFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note,
        size: 22,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
