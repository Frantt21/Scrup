import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';

/// Barra inferior compacta con los controles del reproductor: progreso con
/// tiempos (recorrido/duración), artwork, título/artista, controles centrados
/// y volumen. Alturas fijas en cada zona para que la barra nunca salte.
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
  /// del dedo en la UI (slider y tiempo).
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

  /// Formatea una duración como `m:ss` (dígitos tabulares para que no baile).
  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
    final shownPosition = _dragValue != null
        ? Duration(milliseconds: (_dragValue! * total.inMilliseconds).round())
        : _position;

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progreso compacto con tiempos: recorrido | barra | duración.
              // Altura fija de 24px (pulgar/overlay reducidos para que quepa).
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
                child: SizedBox(
                  height: 24,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          _fmt(hasTrack ? shownPosition : Duration.zero),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 11,
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
                        width: 42,
                        child: Text(
                          _fmt(total),
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Fila principal (altura fija 48px): info | controles | volumen
              SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(child: _buildTrackInfo(theme, cache, player)),
                      const SizedBox(width: 8),
                      _buildControls(theme, player, hasTrack),
                      const SizedBox(width: 8),
                      Expanded(child: _buildVolume(context, theme, player)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Izquierda: artwork + título (con estado de descarga) y artista.
  Widget _buildTrackInfo(
    ThemeData theme,
    AudioCacheService cache,
    PlayerService player,
  ) {
    if (_track == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Sin reproducción',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 36,
            height: 36,
            child: _track!.thumbnailUrl != null
                ? Image.network(
                    _track!.thumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _artworkFallback(theme),
                  )
                : _artworkFallback(theme),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double?>(
                valueListenable: cache.progress,
                builder: (context, downloadPct, _) {
                  return ValueListenableBuilder<String?>(
                    valueListenable: player.preparingTrackId,
                    builder: (context, preparingId, _) {
                      // Solo mostrar el % si la descarga es de la pista que
                      // se está preparando (si el usuario saltó de pista, la
                      // descarga sigue en segundo plano).
                      final downloadingCurrent =
                          cache.downloadingId.value == preparingId;
                      final String label;
                      if (downloadPct != null &&
                          downloadPct < 1 &&
                          downloadingCurrent) {
                        label = 'Descargando… ${(downloadPct * 100).round()}%';
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
          ),
        ),
      ],
    );
  }

  /// Centro: controles de reproducción. Todos los botones usan constraints
  /// explícitos idénticos (34x40) con el play en su propia caja fija, para
  /// que toda la fila quede perfectamente alineada verticalmente.
  Widget _buildControls(ThemeData theme, PlayerService player, bool hasTrack) {
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    const iconSize = 20.0;
    const btnConstraints = BoxConstraints.tightFor(width: 34, height: 40);

    return ValueListenableBuilder<String?>(
      valueListenable: player.preparingTrackId,
      builder: (context, preparingId, _) {
        final preparing = preparingId != null;

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Shuffle
            ValueListenableBuilder<bool>(
              valueListenable: player.shuffle,
              builder: (context, on, _) => IconButton(
                icon: Icon(Icons.shuffle, size: iconSize),
                constraints: btnConstraints,
                padding: EdgeInsets.zero,
                color: on ? primary : muted,
                tooltip: on ? 'Aleatorio: activo' : 'Aleatorio',
                onPressed: player.toggleShuffle,
              ),
            ),
            // Anterior
            IconButton(
              icon: const Icon(Icons.skip_previous),
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: 'Anterior',
              onPressed: hasTrack ? player.previous : null,
            ),
            // Play / Pausa (o loader). Footprint fijo (44x40) para que la
            // barra no cambie de tamaño ni el botón se desalinee.
            SizedBox(
              width: 44,
              height: 40,
              child: Center(
                child: preparing || _buffering
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : IconButton(
                        iconSize: 36,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
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
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
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
                    size: iconSize,
                  ),
                  constraints: btnConstraints,
                  padding: EdgeInsets.zero,
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
                  size: iconSize,
                  color: on ? primary : muted,
                ),
                constraints: btnConstraints,
                padding: EdgeInsets.zero,
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

  /// Derecha: control de volumen compacto (icono con mute + slider corto).
  Widget _buildVolume(
    BuildContext context,
    ThemeData theme,
    PlayerService player,
  ) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return ValueListenableBuilder<double>(
      valueListenable: player.volume,
      builder: (context, vol, _) {
        final icon = vol <= 0
            ? Icons.volume_off
            : (vol < 0.5 ? Icons.volume_down : Icons.volume_up);
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(icon, size: 20),
              constraints: const BoxConstraints.tightFor(width: 34, height: 40),
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: vol <= 0 ? 'Activar sonido' : 'Silenciar',
              onPressed: player.toggleMute,
            ),
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 11,
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
