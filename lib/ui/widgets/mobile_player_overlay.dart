import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';
import '../views/lyrics_view.dart';
import 'cover_image.dart';

/// Contenido del miniplayer ARRASTRABLE (librería `miniplayer`) en Android:
/// un solo widget que se adapta a la `percentage` actuales.
///
/// La transición recogido↔expandido es un **morph** suave: un mismo artwork
/// compartido (absoluto) escala y se reubica desde la barra compacta hasta el
/// centro del player expandido, mientras el contenido cruza con opacidad.
///
/// - **Recogido** (p≈0): barra compacta (artwork 46px, título/artista,
///   play/next/cola y la línea de progreso).
/// - **Expandido** (p≈1): pantalla completa con header dentro de [SafeArea]
///   (botón de cierre `[v]` y letras `[...]`), arte y controles centrados
///   (sin rebote), y un contenedor ARRASTRABLE de letras con el estilo/lógica
///   de escritorio ([LyricsView]).
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

  // Panel de letras (peek arrastrable) dentro del player expandido.
  bool _lyricsOpen = false;

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

    // Tamaño del artwork expandido (72% del ancho, limitado por altura).
    final double artSide = (w * 0.72)
        .clamp(0.0, (fullH * 0.52).clamp(0.0, double.infinity));

    // ────────────────────────────────────────────────────────────────
    // MORPH: el artwork es un único elemento absoluto que escala y se
    // reubica entre la barra compacta (46px, izquierda, arriba) y el
    // centro del player expandido. El resto cruza con opacidad.
    // ────────────────────────────────────────────────────────────────
    return Material(
      clipBehavior: Clip.antiAlias,
      color: cs.surfaceContainerHigh,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Fondo acento de la barra compacta (se desvanece al expandir).
          Positioned.fill(
            child: Opacity(
              opacity: p < 0.02 ? 1.0 : 0.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      accent.withValues(alpha: 0.35),
                      accent.withValues(alpha: 0.1),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Artwork COMPARTIDO (absoluto, escala y se mueve) ─────
          _buildSharedArtwork(
            showing: showing,
            theme: theme,
            accent: accent,
            p: p,
            artSide: artSide,
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
                    child: _compactRow(
                      theme: theme,
                      accent: accent,
                      showing: showing,
                      loading: loading,
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
                  showing: showing,
                  loading: loading,
                  track: track,
                  dur: dur,
                  total: total,
                  w: w,
                  artSide: artSide,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Artwork absoluto que escala de 46px (barra) a `artSide` (centrado).
  Widget _buildSharedArtwork({
    required Track? showing,
    required ThemeData theme,
    required Color accent,
    required double p,
    required double artSide,
    required double w,
  }) {
    final size = lerpDoubleFrom(46, artSide, p);
    final radius = lerpDoubleFrom(6, 18, p);
    final left = lerpDoubleFrom(12, (w - artSide) / 2, p);
    final top = lerpDoubleFrom(7, 64, p);
    final progress = _dur != null && _dur!.inMilliseconds > 0
        ? (_pos.inMilliseconds / _dur!.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Positioned(
      left: left,
      top: top,
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showing == null)
              ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Icon(
                    Icons.music_note_rounded,
                    size: lerpDoubleFrom(22, 56, p),
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35 * p),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: CoverImage(
                    source: (showing.thumbnailUrl != null)
                        ? (Track.hiResThumbnail(showing.thumbnailUrl) ??
                            showing.thumbnailUrl)
                        : null,
                    fit: BoxFit.cover,
                    fallback: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Center(
                        child: Icon(
                          Icons.music_note_rounded,
                          size: lerpDoubleFrom(22, 56, p),
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (p < 0.02)
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
          ],
        ),
      ),
    );
  }

  double lerpDoubleFrom(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);

  /// Fila compacta (título/artista/controles) sobre el artwork compartido.
  Widget _compactRow({
    required ThemeData theme,
    required Color accent,
    required Track? showing,
    required bool loading,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(70, 0, 8, 0),
      child: Row(
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
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              tooltip: _playing ? 'Pausar' : 'Reproducir',
              onPressed: () => _player.togglePlayPause(),
            ),
            IconButton(
              icon: const Icon(Icons.skip_next_rounded),
              tooltip: 'Siguiente',
              onPressed: _player.next,
            ),
            IconButton(
              icon: const Icon(Icons.queue_music_rounded),
              tooltip: 'Cola',
              onPressed: widget.onOpenQueue,
            ),
          ],
        ],
      ),
    );
  }

  // -----------------------------------------------------------------
  // PLAYER EXPANDIDO (pantalla completa, sin arte: el arte es compartido)
  // -----------------------------------------------------------------
  Widget _buildExpanded(
    BuildContext context, {
    required ThemeData theme,
    required ColorScheme cs,
    required Color accent,
    required Track? showing,
    required bool loading,
    required Track? track,
    required Duration? dur,
    required double total,
    required double w,
    required double artSide,
  }) {
    return SafeArea(
      child: Column(
        children: [
          // ── Header dentro del SafeArea: [v] cierre   ...   [...] ──
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
                    color: cs.onSurfaceVariant,
                    tooltip: 'Cerrar',
                    onPressed: widget.onClose,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.lyrics_rounded),
                    color: _lyricsOpen ? accent : cs.onSurfaceVariant,
                    tooltip: 'Letras',
                    onPressed: () => setState(() => _lyricsOpen = true),
                  ),
                ],
              ),
            ),
          ),
          // ── Contenido central centrado: título + controles (sin arte
          //    porque el arte compartido ya está centrado encima) ─────
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      // Empujamos la columna hacia abajo para dejar hueco al
                      // arte compartido (que está centrado un poco más arriba).
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                            height: artSide > 0 ? artSide + 12 : 0),
                        _centerColumn(
                          context,
                          theme: theme,
                          cs: cs,
                          accent: accent,
                          track: track,
                          dur: dur,
                          total: total,
                          w: w,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // ── Panel ARRASTRABLE de letras (peek) ─────────────────────
          _LyricsPeek(
            open: _lyricsOpen,
            onToggle: (v) => setState(() => _lyricsOpen = v),
            accent: accent,
            cs: cs,
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
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            track?.title ?? 'Scrup',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: track == null ? cs.onSurfaceVariant : null,
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
              color: cs.onSurfaceVariant,
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
                  activeTrackColor: accent,
                  inactiveTrackColor: cs.surfaceContainerHighest,
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
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      _fmt(dur),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
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

// ─── Panel de letras arrastrable (peek) ────────────────────────────────
class _LyricsPeek extends StatefulWidget {
  final bool open;
  final ValueChanged<bool> onToggle;
  final Color accent;
  final ColorScheme cs;

  const _LyricsPeek({
    required this.open,
    required this.onToggle,
    required this.accent,
    required this.cs,
  });

  @override
  State<_LyricsPeek> createState() => _LyricsPeekState();
}

/// Contenedor que sobresale unos píxeles con un grip; se arrastra hacia
/// arriba para revelar las letras (reusa la lógica de escritorio de
/// [LyricsView]). Como un scroll interno gana al gesto del panel padre,
/// el arrastre aquí expande/colapsa SOLO las letras, sin colapsar el player.
class _LyricsPeekState extends State<_LyricsPeek> {
  bool _dragging = false;
  double _dragStartExtent = 0;
  double _dragDelta = 0;

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.42;
    final peekH = 46.0;
    final clampedExtent = (widget.open ? maxH + _dragDelta : _dragDelta)
        .clamp(peekH, maxH);

    final height = widget.open || _dragging
        ? clampedExtent
        : peekH.toDouble();

    return AnimatedContainer(
      duration: _dragging
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      height: height,
      decoration: BoxDecoration(
        color: widget.cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(20),
        ),
        border: Border(
          top: BorderSide(
            color: widget.cs.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Grip + título de la sección (arrastrable).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) {
              setState(() {
                _dragging = true;
                _dragStartExtent = widget.open ? maxH : peekH;
                _dragDelta = 0;
              });
            },
            onVerticalDragUpdate: (d) {
              setState(() => _dragDelta = d.primaryDelta ?? 0);
            },
            onVerticalDragEnd: (_) {
              setState(() {
                _dragging = false;
                final extent =
                    (_dragStartExtent + _dragDelta).clamp(peekH, maxH);
                widget.onToggle(extent > maxH * 0.5);
              });
            },
            onTap: () => widget.onToggle(!widget.open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.cs.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.lyrics_rounded,
                    size: 18,
                    color: widget.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Letras',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: widget.cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          // Contenido: letras (solo montadas cuando el panel está abierto).
          Expanded(
            child: Offstage(
              offstage: !widget.open,
              child: TickerMode(
                enabled: widget.open,
                child: const LyricsView(embedded: true),
              ),
            ),
          ),
        ],
      ),
    );
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
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      iconSize: size,
      color: cs.onSurface,
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
        color: accent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.4),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: IconButton(
        iconSize: 40,
        color: Color.lerp(accent, Colors.black, 0.4) ?? Colors.black,
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
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      iconSize: 22,
      color: active ? accent : cs.onSurfaceVariant,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}