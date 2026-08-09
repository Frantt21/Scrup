import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';

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

  /// Posición del slider durante el arrastre: mientras se arrastra NO se
  /// hace seek (el seek real ocurre al soltar), solo se muestra la posición
  /// del dedo en la UI.
  double? _dragValue;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _subs.addAll([
      player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() {
          _track = t;
          _dragValue = null;
        });
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
    final themeController = context.watch<ThemeController>();
    final hasTrack = _track != null;
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // Durante el arrastre se muestra la posición del dedo; el seek real se
    // hace al soltar (onChangeEnd), no en cada tick.
    final shownProgress = _dragValue ?? progress;

    return Material(
      elevation: 12,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Container(
        // Tinte sutil del color del artwork, desvaneciéndose hacia la derecha
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              themeController.accentColor?.withValues(alpha: 0.20) ??
                  Colors.transparent,
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Barra de progreso (altura fija para que la barra no salte;
                // 28px para no recortar el overlay del pulgar al pulsar)
                SizedBox(
                  height: 28,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      value: shownProgress,
                      onChanged: hasTrack
                          ? (v) => setState(() => _dragValue = v)
                          : null,
                      onChangeEnd: hasTrack
                          ? (v) {
                              final target = Duration(
                                milliseconds: (v * total.inMilliseconds)
                                    .round(),
                              );
                              player.seek(target);
                              setState(() => _dragValue = null);
                            }
                          : null,
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      // Izquierda: artwork + metadatos
                      Expanded(
                        child: Row(
                          children: [
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ValueListenableBuilder<double?>(
                                          valueListenable: cache.progress,
                                          builder: (context, downloadPct, _) {
                                            return ValueListenableBuilder<
                                              String?
                                            >(
                                              valueListenable:
                                                  player.preparingTrackId,
                                              builder: (context, preparingId, _) {
                                                // Solo mostrar el % si la descarga
                                                // es de la pista que se está
                                                // preparando (si el usuario saltó
                                                // de pista, la descarga sigue en
                                                // segundo plano).
                                                final downloadingCurrent =
                                                    cache.downloadingId.value ==
                                                    preparingId;
                                                final String label;
                                                if (downloadPct != null &&
                                                    downloadPct < 1 &&
                                                    downloadingCurrent) {
                                                  label =
                                                      'Descargando… '
                                                      '${(downloadPct * 100).round()}%';
                                                } else if (preparingId !=
                                                    null) {
                                                  label = 'Preparando…';
                                                } else {
                                                  label = _track!.title;
                                                }
                                                return Text(
                                                  label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .titleSmall,
                                                );
                                              },
                                            );
                                          },
                                        ),
                                        Text(
                                          _track!.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      'Sin reproducción',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Centro: controles de reproducción
                      _buildControls(context, theme, player, hasTrack),
                      const SizedBox(width: 8),
                      // Derecha: volumen
                      Expanded(child: _buildVolume(context, theme, player)),
                    ],
                  ),
                ),
              ],
            ),
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
            // Play / Pausa (o loader). Footprint fijo (56x48) para que la
            // barra no cambie de altura al alternar entre botón y spinner.
            SizedBox(
              width: 56,
              height: 48,
              child: Center(
                child: preparing || _buffering
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : IconButton(
                        iconSize: 40,
                        icon: Icon(
                          _playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: primary,
                        ),
                        tooltip: _playing ? 'Pausar' : 'Reproducir',
                        onPressed: hasTrack ? player.togglePlayPause : null,
                      ),
              ),
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
                icon: Icon(Icons.radio, size: 20, color: on ? primary : muted),
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

  /// Control de volumen: icono (con mute) + slider, alineado a la derecha.
  Widget _buildVolume(
    BuildContext context,
    ThemeData theme,
    PlayerService player,
  ) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return ValueListenableBuilder<double>(
      valueListenable: player.volume,
      builder: (context, vol, _) {
        // Icono: mute / bajo / alto. Tocar silencia o restaura.
        final icon = vol <= 0
            ? Icons.volume_off
            : (vol < 0.5 ? Icons.volume_down : Icons.volume_up);
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(icon, size: 20),
              color: muted,
              tooltip: vol <= 0 ? 'Activar sonido' : 'Silenciar',
              onPressed: player.toggleMute,
            ),
            SizedBox(
              width: 110,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: vol.clamp(0.0, 1.0),
                  onChanged: player.setVolume,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
