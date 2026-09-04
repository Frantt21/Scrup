import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme_controller.dart';

import '../../core/track.dart';
import '../../core/app_log.dart';
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
  Track? _preparing;
  bool _preparingActive = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  Timer? _ticker;

  final List<StreamSubscription> _subs = [];
  VoidCallback? _onPreparingChanged;
  VoidCallback? _onQueueChanged;

  Color? _lastLoggedAccent;
  String? _lastLoggedTrackId;

  /// Acento anterior para el fundido: el tween arranca del color REAL
  /// previo (no de transparente) hacia el nuevo.
  Color? _prevAccent;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _track = player.currentTrackValue;
    _duration = player.durationValue;
    _syncPreparing(player);
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
    _onPreparingChanged = () {
      if (mounted) _syncPreparing(player);
    };
    _onQueueChanged = () {
      if (mounted) _syncPreparing(player);
    };
    player.preparingTrackId.addListener(_onPreparingChanged!);
    player.queue.addListener(_onQueueChanged!);
    if (player.currentTrackValue != null) {
      _ticker = _startTicker();
    }
  }

  /// Mantiene la pista "en preparación" (cargando) para que el mini-player
  /// NO desaparezca al cambiar de canción: mientras se resuelve la fuente,
  /// mostramos la pista entrante con un indicador de carga.
  void _syncPreparing(PlayerService player) {
    final id = player.preparingTrackId.value;
    Track? found;
    if (id != null) {
      for (final t in player.queue.value) {
        if (t.id == id) {
          found = t;
          break;
        }
      }
    }
    final active = id != null;
    if (found?.id != _preparing?.id || active != _preparingActive) {
      setState(() {
        _preparing = found;
        _preparingActive = active;
      });
      // Igual que en el player extendido: precarga el acento de la pista
      // entrante para que la transición no pase por el color por defecto.
      if (found != null) {
        context.read<ThemeController>().warmAccent(found.thumbnailUrl);
      }
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
    final player = context.read<PlayerService>();
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (_onPreparingChanged != null) {
      player.preparingTrackId.removeListener(_onPreparingChanged!);
    }
    if (_onQueueChanged != null) {
      player.queue.removeListener(_onQueueChanged!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final themeController = context.watch<ThemeController>();
    // Igual que el extendido: sin acento aún, tinte neutro invisible en vez
    // del lila del tema.
    final accent = themeController.accentColor ?? Colors.transparent;

    // El mini-player está SIEMPRE montado a altura fija (barra persistente):
    //   · track != null            → reproducción normal.
    //   · track == null + loading  → pista entrante con indicador de carga.
    //   · track == null + idle     → barra placeholder ("Nada en reproducción").
    // Así nunca desaparece al cambiar de canción ni durante la carga.
    final Track? showing = track ?? (_preparingActive ? _preparing : null);
    final bool loading = track == null && _preparingActive;
    if (_lastLoggedAccent != accent || _lastLoggedTrackId != showing?.id) {
      appLog(
        'UI',
        'mini accent=${colorHex(accent)} showing=${shortId(showing?.id)} '
        'loading=$loading',
      );
      _lastLoggedAccent = accent;
      _lastLoggedTrackId = showing?.id;
    }

    final progress = _duration != null && _duration!.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration!.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Fundido RGB origen→destino (igual que el extendido): `ValueKey`
    // reinicia la animación en cada cambio de acento partiendo del color
    // previo real, sin salto a transparente ni tercer color intermedio.
    final begin = _prevAccent ?? accent;
    _prevAccent = accent;
    return Material(
      clipBehavior: Clip.antiAlias,
      // Mismo acento del player desktop, en PLANO (sin degradado): base
      // translúcida + acento uniforme en todo el fondo del mini-player.
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Stack(
        children: [
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              key: ValueKey(accent),
              tween: ColorTween(begin: begin, end: accent),
              duration: const Duration(milliseconds: 350),
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
          if (track != null)
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
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: showing == null ? null : widget.onOpenNowPlaying,
              child: SizedBox(
                height: 60,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: showing == null
                              ? Container(
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    size: 22,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : CoverImage(
                                  source: showing.thumbnailUrl,
                                  fit: BoxFit.cover,
                                  fallback: Container(
                                    color:
                                        theme.colorScheme.surfaceContainerHigh,
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
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
                              showing?.title ?? 'Scrup',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: showing == null
                                    ? theme.colorScheme.onSurfaceVariant
                                    : null,
                              ),
                            ),
                            if (showing != null && showing.artist.isNotEmpty)
                              Text(
                                loading ? 'Cargando…' : showing.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            if (showing == null)
                              Text(
                                'Nada en reproducción',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      else if (showing != null) ...[
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
