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
    // Referencia de altura FINAL (pantalla completa) para dimensionar el arte.
    final double fullH = MediaQuery.sizeOf(context).height;
    // Progreso de ESCALA del arte derivado de la ALTURA REAL del panel
    // (60 → fullH), no del porcentaje posiblemente curvado. Así el artwork
    // empieza a escalar desde el primer instante y sigue siempre al panel.
    final double hp = ((widget.height - 60) / (fullH - 60)).clamp(0.0, 1.0);

    // Tamaño del artwork expandido (grande, 1:1), limitado por la altura
    // disponible para dejar espacio a header + bloque de controles.
    final double headerH = 64.0;
    final double controlsBand = 300.0;
    final double availH = (fullH - headerH - controlsBand).clamp(120.0, double.infinity);
    final double artSide = (w * 0.82).clamp(120.0, availH);

    // Posición expandida del arte: centrado en X y centrado verticalmente
    // en la franja entre el header y el bloque de controles.
    final double artLeft = (w - artSide) / 2;
    final double artTop = headerH + (availH - artSide) / 2;

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
            p: hp,
            artSide: artSide,
            artLeft: artLeft,
            artTop: artTop,
            w: w,
          ),

          // ── Contenido COMPACTO (la barra se va al INICIO de la transición) ──
          Positioned.fill(
            child: IgnorePointer(
              ignoring: p > 0.05,
              child: Opacity(
                // Se desvanece rápido: desaparece por completo ya al ~15% de
                // la expansión (no se queda desvaneciéndose durante toda la
                // transición).
                opacity: ((1 - p * 6.7)).clamp(0.0, 1.0),
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
                          // Progreso en la base, DETRÁS de los elementos
                          // (sólo sobre el fondo, no sobre título/controles).
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
                                color: Colors.black.withValues(alpha: 0.25),
                              ),
                            ),
                          ),
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
                  hp: hp,
                  artSide: artSide,
                  artTop: artTop,
                ),
              ),
            ),
          ),

          // ── Letras MONTADAS (sólo en el expandido): sheet draggable que se
          //    abre arrastrándola. Vive FUERA del SafeArea para que el fondo
          //    plano del sheet se extienda también sobre la barra de
          //    navegación del sistema.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: p < 0.98,
              child: Opacity(
                opacity: p,
                child: _LyricsPeek(
                  track: track,
                  accent: accent,
                  open: _lyricsOpen,
                  onChanged: (v) => setState(() => _lyricsOpen = v),
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
    required double hp,
    required double artSide,
    required double artTop,
  }) {
    final safeTop = MediaQuery.paddingOf(context).top;
    // El arte está en coords de pantalla completa; el contenido de la columna
    // vive debajo del header (52) + SafeArea. El espaciador coloca los
    // controles justo debajo del borde inferior del arte, siguiéndolo con la
    // misma escala (`hp`) para que arranquen juntos desde el primer instante.
    final double artBottomP = lerp(7, artTop, hp) + lerp(46, artSide, hp);
    final double controlsTop = (artBottomP - 52 - safeTop).clamp(0.0, double.infinity);

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
          // ── Contenido: controles justo debajo del arte heredado ─────
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        SizedBox(height: controlsTop),
                        Padding(
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
                          ),
                        ),
                      ],
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
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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

/// Panel de letras MONTADO en el player expandido: siempre visible como un
/// handle en la base, que se abre ("despliega") arrastrándolo hacia arriba y
/// se cierra arrastrándolo hacia abajo o pulsando el handle/la «X».
///
/// El sheet se desliza por encima de los controles (como en forawn_mobile),
/// cubriéndolos mientras está abierto, y muestra las letras con
/// [LyricsView] en modo `embedded`.
class _LyricsPeek extends StatefulWidget {
  final Track? track;
  final Color accent;
  final bool open;
  final ValueChanged<bool> onChanged;

  const _LyricsPeek({
    required this.track,
    required this.accent,
    required this.open,
    required this.onChanged,
  });

  @override
  State<_LyricsPeek> createState() => _LyricsPeekState();
}

class _LyricsPeekState extends State<_LyricsPeek> {
  /// 0 = recogido (solo handle), 1 = abierto. Se anima con [AnimatedContainer].
  double _open = 0.0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _open = widget.open ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(covariant _LyricsPeek oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open != oldWidget.open && !_dragging) {
      _open = widget.open ? 1.0 : 0.0;
    }
  }

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d, double refH) {
    setState(() {
      _open = (_open - d.delta.dy / (refH * 0.7)).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    final target = _open > 0.5;
    setState(() => _open = target ? 1.0 : 0.0);
    if (target != widget.open) widget.onChanged(target);
  }

  void _toggle() {
    final target = _open < 0.5;
    setState(() => _open = target ? 1.0 : 0.0);
    widget.onChanged(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Fondo PLANO: acento oscurecido (no translúcido), para que el sheet
    // contraste con el acento del player y se extienda sobre la barra de
    // navegación.
    final Color sheetColor = Color.lerp(widget.accent, Colors.black, 0.35)!;
    return Align(
      alignment: Alignment.bottomCenter,
      child: LayoutBuilder(
        builder: (context, c) {
          final maxH = c.maxHeight;
          final collapsed = 48.0;
          final openH = maxH * 0.80;
          final sheetH = collapsed + (_open * (openH - collapsed));

          return AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: sheetH,
            width: double.infinity,
            decoration: BoxDecoration(
              color: sheetColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                // Handle (siempre visible, ~48px). El arrastre está acotado
                // al handle para no chocar con el scroll de las letras.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: (d) => _onDragUpdate(d, maxH),
                  onVerticalDragEnd: _onDragEnd,
                  onTap: _toggle,
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Letras',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _open >= 0.5
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded,
                          ),
                          color: Colors.white.withValues(alpha: 0.9),
                          onPressed: _toggle,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                // Letras SIEMPRE MONTADAS (no aparecen de golpe); el
                // [AnimatedContainer] las revela escalando la altura.
                Expanded(
                  child: LyricsView(embedded: true),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}