import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';
import 'cover_image.dart';

/// Contenido del miniplayer ARRASTRABLE (librería `miniplayer`) en Android:
/// un solo widget que se adapta a la `percentage` actuales.
///
/// La transición recogido↔expandido es un **morph** suave: el MISMO artwork
/// compartido (absoluto en un Stack) escala y se reubica desde la barra
/// compacta hasta el player expandido, mientras el contenido cruza con
/// opacidad. El fondo es el acento plano en ambos estados.
///
/// - **Recogido** (p≈0): barra compacta (artwork 46px, título/artista,
///   play/next/cola centrados verticalmente y línea de progreso).
/// - **Expandido** (p≈1): pantalla completa con header dentro de [SafeArea]
///   (botón de cierre `[v]`), arte grande 1:1 heredado (el mismo de la barra)
///   y controles centrados debajo (sin rebote).
class MobilePlayerOverlay extends StatefulWidget {
  /// Altura actual del panel (desde el builder de `Miniplayer`).
  final double height;

  /// Progreso de expansión 0..1 (desde el builder de `Miniplayer`).
  final double percentage;

  /// Abre la cola.
  final VoidCallback onOpenQueue;

  /// Cierra (colapsa) el player expandido.
  final VoidCallback onClose;

  const MobilePlayerOverlay({
    super.key,
    required this.height,
    required this.percentage,
    required this.onOpenQueue,
    required this.onClose,
  });

  @override
  State<MobilePlayerOverlay> createState() => _MobilePlayerOverlayState();
}

class _MobilePlayerOverlayState extends State<MobilePlayerOverlay> {
  late final PlayerService _player;
  Track? _track;
  Track? _preparing;
  bool _preparingActive = false;
  Duration _pos = Duration.zero;
  Duration? _dur;
  bool _playing = false;
  bool _buffering = false;
  bool _dragging = false;
  double _dragValue = 0;

  final List<StreamSubscription> _subs = [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerService>();
    _track = _player.currentTrackValue;
    _pos = _player.positionValue;
    _dur = _player.durationValue;
    _playing = _player.isPlaying;
    _subs.addAll([
      _player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() => _track = t);
        if (t != null) _ticker ??= _startTicker();
      }),
      _player.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      }),
      _player.buffering.listen((b) {
        if (!mounted) return;
        setState(() => _buffering = b);
      }),
      _player.position.listen((p) {
        if (!mounted) return;
        if (_dragging) return;
        setState(() => _pos = p);
      }),
      _player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _dur = d);
      }),
    ]);
    _player.preparingTrackId.addListener(_onPreparing);
    _onPreparing();
    if (_playing) _ticker = _startTicker();
  }

  void _onPreparing() {
    final id = _player.preparingTrackId.value;
    if (!mounted) return;
    setState(() {
      _preparingActive = id != null;
      _preparing = null;
      if (id != null) {
        for (final t in _player.queue.value) {
          if (t.id == id) {
            _preparing = t;
            break;
          }
        }
      }
    });
  }

  Timer? _startTicker() {
    return Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _dragging) return;
      final pos = _player.positionValue;
      if (pos != _pos) setState(() => _pos = pos);
    });
  }

  @override
  void dispose() {
    _player.preparingTrackId.removeListener(_onPreparing);
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  double get _maxProgress {
    final d = _dur?.inMilliseconds ?? 0;
    return d > 0 ? d.toDouble() : 0;
  }

  double get _progressValue {
    if (_maxProgress <= 0) return 0;
    return (_dragging ? _dragValue : _pos.inMilliseconds.toDouble())
        .clamp(0.0, _maxProgress)
        .toDouble();
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) {
      final mm = d.inHours * 60 + d.inMinutes.remainder(60);
      return '$mm:${s.toString().padLeft(2, '0')}';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeController = context.watch<ThemeController>();
    final accent = themeController.accentColor ?? theme.colorScheme.primary;
    final cs = theme.colorScheme;

    final track = _track;
    final Track? showing = track ?? (_preparingActive ? _preparing : null);
    final bool loading = track == null && _preparingActive;
    final dur = _dur;
    final total = _maxProgress;

    final double p = widget.percentage.clamp(0.0, 1.0);
    final w = MediaQuery.sizeOf(context).width;
    final fullH = widget.height;

    // Tamaño del artwork expandido (grande, 1:1), limitado por la altura
    // disponible para dejar espacio a header + controles.
    final double artSide = (w * 0.82)
        .clamp(120.0, ((fullH - 300).clamp(120.0, double.infinity)));

    // Posición expandida del arte: justo debajo del header, centrado en X.
    final double artLeft = (w - artSide) / 2;
    final double artTop = 76.0;

    return Material(
      clipBehavior: Clip.antiAlias,
      color: accent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Artwork COMPARTIDO: el mismo elemento en ambos estados ──
          _sharedArtwork(
            showing: showing,
            theme: theme,
            p: p,
            artSide: artSide,
            artLeft: artLeft,
            artTop: artTop,
            w: w,
          ),

          // ── Contenido COMPACTO (se desvanece al expandir) ─────────
          Positioned.fill(
            child: IgnorePointer(
              ignoring: p > 0.02,
              child: Opacity(
                opacity: (1 - p).clamp(0.0, 1.0),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: 60,
                    width: w,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.12),
                      ),
                      child: Stack(
                        children: [
                          // Fila centrada verticalmente (título/controles).
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(70, 0, 8, 0),
                              child: _compactRow(
                                theme: theme,
                                accent: accent,
                                showing: showing,
                                loading: loading,
                              ),
                            ),
                          ),
                          // Progreso personalizado (relleno blanco en la base).
                          Align(
                            alignment: Alignment.bottomLeft,
                            child: FractionallySizedBox(
                              widthFactor: _dur != null &&
                                      _dur!.inMilliseconds > 0
                                  ? (_pos.inMilliseconds /
                                          _dur!.inMilliseconds)
                                      .clamp(0.0, 1.0)
                                  : 0.0,
                              heightFactor: 1.0,
                              child: Container(
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Contenido EXPANDIDO (aparece al expandir) ─────────────
          Positioned.fill(
            child: IgnorePointer(
              ignoring: p < 0.98,
              child: Opacity(
                opacity: p,
                child: _buildExpanded(
                  context,
                  theme: theme,
                  cs: cs,
                  accent: accent,
                  track: track,
                  dur: dur,
                  total: total,
                  w: w,
                  p: p,
                  artSide: artSide,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Artwork heredado: escala y se reubica entre la barra (46px, arriba-izq.)
  /// y el expandido (grande, centrado debajo del header).
  Widget _sharedArtwork({
    required Track? showing,
    required ThemeData theme,
    required double p,
    required double artSide,
    required double artLeft,
    required double artTop,
    required double w,
  }) {
    final size = lerp(46, artSide, p);
    final radius = lerp(6, 18, p);
    final left = lerp(12, artLeft, p);
    final top = lerp(7, artTop, p);

    return Positioned(
      left: left,
      top: top,
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: showing == null
            ? ColoredBox(
                color: Colors.black.withValues(alpha: 0.18),
                child: Center(
                  child: Icon(
                    Icons.music_note_rounded,
                    size: lerp(22, 56, p),
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              )
            : CoverImage(
                source: showing.thumbnailUrl != null
                    ? (Track.hiResThumbnail(showing.thumbnailUrl) ??
                        showing.thumbnailUrl)
                    : null,
                fit: BoxFit.cover,
                fallback: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.18),
                  child: Center(
                    child: Icon(
                      Icons.music_note_rounded,
                      size: lerp(22, 56, p),
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  double lerp(double a, double b, double t) => a + (b - a) * t.clamp(0.0, 1.0);

  /// Fila compacta (título/artista/controles), ya centrada verticalmente.
  Widget _compactRow({
    required ThemeData theme,
    required Color accent,
    required Track? showing,
    required bool loading,
  }) {
    return Row(
      children: [
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
                      ? Colors.white.withValues(alpha: 0.8)
                      : Colors.white,
                ),
              ),
              if (showing != null && showing.artist.isNotEmpty)
                Text(
                  loading ? 'Cargando…' : showing.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              if (showing == null)
                Text(
                  'Nada en reproducción',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
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
            color: Colors.white,
            icon: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            tooltip: _playing ? 'Pausar' : 'Reproducir',
            onPressed: () => _player.togglePlayPause(),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.skip_next_rounded),
            tooltip: 'Siguiente',
            onPressed: _player.next,
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.queue_music_rounded),
            tooltip: 'Cola',
            onPressed: widget.onOpenQueue,
          ),
        ],
      ],
    );
  }

  // -----------------------------------------------------------------
  // PLAYER EXPANDIDO (pantalla completa)
  // -----------------------------------------------------------------
  Widget _buildExpanded(
    BuildContext context, {
    required ThemeData theme,
    required ColorScheme cs,
    required Color accent,
    required Track? track,
    required Duration? dur,
    required double total,
    required double w,
    required double p,
    required double artSide,
  }) {
    return SafeArea(
      child: Column(
        children: [
          // ── Header: [v] cierre ────────────────────────────────────
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 28,
                    ),
                    color: Colors.white.withValues(alpha: 0.9),
                    tooltip: 'Cerrar',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
          // ── Contenido: controles justo debajo del arte heredado. El
          //    espaciado crece con `p`, siguiendo el borde inferior del arte
          //    en su transición (sin huecos, sin esperarle).
          Flexible(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _centerColumn(
                          context,
                          theme: theme,
                          cs: cs,
                          accent: accent,
                          track: track,
                          dur: dur,
                          total: total,
                          w: w,
                          p: p,
                          artSide: artSide,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _centerColumn(
    BuildContext context, {
    required ThemeData theme,
    required ColorScheme cs,
    required Color accent,
    required Track? track,
    required Duration? dur,
    required double total,
    required double w,
    required double p,
    required double artSide,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Deja hueco al arte heredado (que está por encima en el Stack). El
        // hueco crece con `p` para seguir el borde inferior del arte durante
        // la transición (sin huecos estáticos ni esperas).
        SizedBox(height: lerp(64, artSide, p)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            track?.title ?? 'Scrup',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: track == null
                  ? Colors.white.withValues(alpha: 0.8)
                  : Colors.white,
            ),
          ),
        ),
        if (track != null && track.artist.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Progreso + tiempos
        SizedBox(
          width: w - 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                ),
                child: Slider(
                  value: total <= 0 ? 0 : _progressValue.clamp(0.0, total),
                  max: total <= 0 ? 1 : total,
                  onChangeStart: (_) => setState(() => _dragging = true),
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    _player.seek(Duration(milliseconds: v.round()));
                    setState(() {
                      _dragging = false;
                      _pos = Duration(milliseconds: v.round());
                    });
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(_dragging
                          ? Duration(milliseconds: _dragValue.round())
                          : _pos),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    Text(
                      _fmt(dur),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Transporte
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ModeButton(
              icon: Icons.shuffle_rounded,
              active: _player.shuffle.value,
              accent: accent,
              onPressed: _player.toggleShuffle,
            ),
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              size: 34,
              onPressed: track == null ? null : _player.previous,
            ),
            _PlayPauseButton(
              playing: _playing,
              accent: accent,
              onPressed: track == null ? null : _player.togglePlayPause,
            ),
            _ControlButton(
              icon: Icons.skip_next_rounded,
              size: 34,
              onPressed: track == null ? null : _player.next,
            ),
            _ModeButton(
              icon: _repeatIcon(_player.repeatMode.value),
              active: _player.repeatMode.value != LoopMode.off,
              accent: accent,
              onPressed: _player.toggleRepeat,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_buffering && track != null) ...[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  IconData _repeatIcon(LoopMode mode) {
    switch (mode) {
      case LoopMode.off:
        return Icons.repeat_rounded;
      case LoopMode.all:
        return Icons.repeat_rounded;
      case LoopMode.one:
        return Icons.repeat_one_rounded;
    }
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: size,
      color: Colors.white.withValues(alpha: 0.9),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool playing;
  final Color accent;
  final VoidCallback? onPressed;

  const _PlayPauseButton({
    required this.playing,
    required this.accent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        iconSize: 40,
        color: accent,
        onPressed: onPressed,
        icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color accent;
  final VoidCallback onPressed;

  const _ModeButton({
    required this.icon,
    required this.active,
    required this.accent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: 22,
      color: active
          ? Colors.white
          : Colors.white.withValues(alpha: 0.6),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}