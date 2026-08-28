import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';

/// Fullscreen mode: the player IS the app.
/// Animated entry/exit with three-zone layout (art + controls, lyrics, header).
class FullscreenPlayerView extends StatefulWidget {
  final bool active;
  final Widget lyricsPanel;
  final VoidCallback onRequestClose;
  final VoidCallback onExited;

  const FullscreenPlayerView({
    super.key,
    required this.active,
    required this.lyricsPanel,
    required this.onRequestClose,
    required this.onExited,
  });

  @override
  State<FullscreenPlayerView> createState() => _FullscreenPlayerViewState();
}

class _FullscreenPlayerViewState extends State<FullscreenPlayerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition;
  Track? _track;
  late final PlayerService _player;
  List<Color> _palette = const [];
  String? _artPath;

  StreamSubscription<Track?>? _trackSub;
  int _visualToken = 0;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerService>();
    _track = _player.currentTrackValue;
    _transition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..addStatusListener(_onTransitionStatus);
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _transition.forward();
      });
    }
    _trackSub = _player.currentTrack.listen((t) {
      if (!mounted || t?.id == _track?.id) return;
      _loadTrackVisuals(t);
    });
    _player.queueIndex.addListener(_prefetchNextListener);
    _player.queue.addListener(_prefetchNextListener);
    _loadTrackVisuals(_track);
  }

  void _prefetchNextListener() => unawaited(_prefetchNext());

  void _onTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.active && mounted) {
      widget.onExited();
    }
  }

  @override
  void didUpdateWidget(FullscreenPlayerView old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      widget.active ? _transition.forward() : _transition.reverse();
    }
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _prefetchTimer?.cancel();
    _player.queueIndex.removeListener(_prefetchNextListener);
    _player.queue.removeListener(_prefetchNextListener);
    _transition.dispose();
    super.dispose();
  }

  // ── Artwork hi-res + palette (two phases) ──────────────────────────

  static final Set<String> _ensuredUrls = {};
  static final Map<String, List<Color>> _trioCache = {};

  Timer? _prefetchTimer;

  // Phase 1: load artwork to disk and show immediately.
  Future<void> _loadTrackVisuals(Track? track) async {
    final token = ++_visualToken;
    final rawUrl = track?.thumbnailUrl;
    if (rawUrl == null || rawUrl.isEmpty) {
      if (mounted) {
        setState(() {
          _track = track;
          _artPath = null;
          _palette = const [];
        });
      }
      return;
    }

    // Phase 1: artwork only (file path).
    final artworkCache = context.read<ArtworkCacheService>();
    String? path;
    final lower = rawUrl.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      try {
        final f = File(rawUrl);
        if (await f.exists()) {
          path = rawUrl;
          _ensuredUrls.add(rawUrl);
        }
      } catch (_) {}
    }
    path ??= await artworkCache.filePathFor(rawUrl);

    if (path == null) {
      Uint8List? bytes;
      for (final url in [Track.hiResThumbnail(rawUrl) ?? rawUrl, rawUrl]) {
        try {
          final resp = await http
              .get(
                Uri.parse(url),
                headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
              )
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
            bytes = resp.bodyBytes;
            break;
          }
        } catch (_) {}
      }
      if (bytes != null) {
        await artworkCache.save(rawUrl, bytes);
        path = await artworkCache.filePathFor(rawUrl);
      }
    }

    if (!mounted || token != _visualToken) return;

    if (path != null) _ensuredUrls.add(rawUrl);
    setState(() {
      _track = track;
      _artPath = path;
    });

    // Phase 2: palette in background.
    _loadPalettePhase2(rawUrl, token);
  }

  // Phase 2: extract color trio without blocking artwork display.
  Future<void> _loadPalettePhase2(String rawUrl, int token) async {
    final paletteStore = context.read<PaletteCacheStore>();
    final artworkCache = context.read<ArtworkCacheService>();

    var trio = _trioCache[rawUrl];
    if (trio == null) {
      final saved = paletteStore.getTrio(rawUrl);
      if (saved != null) {
        trio = saved;
        _trioCache[rawUrl] = trio;
      }
    }

    if (trio == null) {
      final bytes = await artworkCache.load(rawUrl);
      if (bytes != null) {
        trio = await ArtworkPaletteService.trioFromBytes(
          rawUrl,
          bytes,
          paletteStore,
        );
        if (trio.isNotEmpty) _trioCache[rawUrl] = trio;
      }
    }

    if (!mounted || token != _visualToken) return;
    if (trio != null && trio.isNotEmpty) {
      setState(() => _palette = trio!);
    } else if (_palette.isNotEmpty) {
      // Clear old palette when new artwork has no colors.
      setState(() => _palette = const []);
    }
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) unawaited(_prefetchNext());
    });
  }

  // Prefetches artwork + palette for the next 3 queue tracks.
  Future<void> _prefetchNext() async {
    if (!mounted) return;
    final player = context.read<PlayerService>();
    final q = player.queue.value;
    final start = player.queueIndex.value + 1;
    if (start < 0 || start >= q.length) return;

    for (var offset = 0; offset < 3 && start + offset < q.length; offset++) {
      final url = q[start + offset].thumbnailUrl;
      if (url == null || url.isEmpty) continue;
      if (_ensuredUrls.contains(url) && _trioCache.containsKey(url)) continue;

        if (!mounted) return;
      final artworkCache = context.read<ArtworkCacheService>();
      var path = await artworkCache.filePathFor(url);
      if (path == null) {
        // Descargar si no está en caché.
        for (final dlUrl in [Track.hiResThumbnail(url) ?? url, url]) {
          try {
            final resp = await http
                .get(
                  Uri.parse(dlUrl),
                  headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
                )
                .timeout(const Duration(seconds: 10));
            if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
              await artworkCache.save(url, resp.bodyBytes);
              path = await artworkCache.filePathFor(url);
              break;
            }
          } catch (_) {}
        }
      }

      if (mounted && path != null) {
        _ensuredUrls.add(url);
        try {
          await precacheImage(FileImage(File(path)), context);
        } catch (_) {}
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _palette;

    return AnimatedBuilder(
      animation: _transition,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_transition.value);
        return Material(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: t,
                child: RepaintBoundary(
                  child: _AnimatedBackdrop(colors: palette),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                final artSide = math
                      .min(size.height - 250, 620.0)
                      .clamp(240.0, 720.0);
                  const gap = 56.0;
                  var lyricsW = (size.width * 0.36).clamp(340.0, 660.0);
                  if (artSide + gap + lyricsW > size.width - 96) {
                    lyricsW = math.max(280.0, size.width - 96 - artSide - gap);
                  }
                  final contentW = artSide + gap + lyricsW;
                  final leftX = (size.width - contentW) / 2;
                  final artBottom = size.height / 2 + artSide / 2;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            FractionalTranslation(
                              translation: Offset(-(1 - t), 0),
                              child: Opacity(
                                opacity: t,
                                child: _LeftColumn(
                                  artSide: artSide,
                                  track: _track,
                                  artPath: _artPath,
                                ),
                              ),
                            ),
                            const SizedBox(width: gap),
                            FractionalTranslation(
                              translation: Offset(1 - t, 0),
                              child: Opacity(
                                opacity: t,
                                child: SizedBox(
                                  width: lyricsW,
                                  height: math.min(artSide, size.height - 140),
                                  child: widget.lyricsPanel,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        top: artBottom + 18,
                        left: leftX,
                        width: artSide,
                        child: Opacity(
                          opacity: t,
                          child: const _FloatingControls(),
                        ),
                      ),
                    ],
                  );
                },
              ),
              Align(
                alignment: Alignment.topCenter,
                child: FractionalTranslation(
                  translation: Offset(0, -(1 - t) * 0.6),
                  child: Opacity(
                    opacity: t,
                    child: _CenterHeader(track: _track),
                  ),
                ),
              ),
              Positioned(
                top: 18,
                right: 18,
                child: Opacity(
                  opacity: t,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 24),
                    color: theme.colorScheme.onSurfaceVariant,
                    tooltip: AppLocalizations.of(context).close,
                    onPressed: widget.onRequestClose,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Fondo animado: olas verticales ────────────────────────────────────────

/// Animated liquid backdrop with three colors from artwork palette.
/// Colors interpolate smoothly on track changes.
class _AnimatedBackdrop extends StatefulWidget {
  final List<Color> colors;

  const _AnimatedBackdrop({required this.colors});

  @override
  State<_AnimatedBackdrop> createState() => _AnimatedBackdropState();
}

class _AnimatedBackdropState extends State<_AnimatedBackdrop>
    with TickerProviderStateMixin {
  late final AnimationController _fade;

  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Ticker _ticker;

  ui.FragmentProgram? _program;

  List<Color> _from = const [];
  List<Color> _target = const [];

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      value: 1,
    );
    _target = _padded(widget.colors);
    _from = _target;
    _ticker = createTicker((elapsed) {
      _clock.value = elapsed.inMicroseconds / 1e6;
    });
    _ticker.start();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_bg.frag',
      );
      if (!mounted) return;
      setState(() => _program = program);
    } catch (_) {
      }
  }

  @override
  void didUpdateWidget(_AnimatedBackdrop old) {
    super.didUpdateWidget(old);
    final next = _padded(widget.colors);
    if (!listEquals(next, _target)) {
      _from = _shown();
      _target = next;
      _fade.forward(from: 0);
    }
  }

  static const _fallbackPalette = [
    Color(0xFF111111),
    Color(0xFF1A1A1A),
    Color(0xFF252525),
  ];

  List<Color> _padded(List<Color> src) => [
    for (var i = 0; i < 3; i++) i < src.length ? src[i] : _fallbackPalette[i],
  ];

  List<Color> _shown() {
    final t = Curves.easeOutCubic.transform(_fade.value);
    return [for (var i = 0; i < 3; i++) Color.lerp(_from[i], _target[i], t)!];
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    return ColoredBox(
      color: const Color(0xFF050505),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_clock, _fade]),
          builder: (context, _) {
            final colors = _shown();
            if (program != null) {
              return CustomPaint(
                size: Size.infinite,
                painter: _LiquidPainter(program, _clock.value, colors),
              );
            }
            return CustomPaint(
              size: Size.infinite,
              painter: _WatercolorPainter(t: _clock.value, colors: colors),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    _fade.dispose();
    super.dispose();
  }
}

/// Fondo LÍQUIDO vía fragment shader (shaders/liquid_bg.frag): fbm con
/// doble domain warping — flujo continuo, borde a borde, sin viñeta. Los
/// colores llegan ya interpolados desde [_AnimatedBackdropState._shown].
class _LiquidPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double time;
  final List<Color> colors;

  _LiquidPainter(this.program, this.time, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    // Orden de uniforms = orden de declaración en el .frag (sin sampler).
    // r/g/b ya vienen normalizados 0..1 (colores double en Flutter).
    final shader = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, colors[0].r)
      ..setFloat(4, colors[0].g)
      ..setFloat(5, colors[0].b)
      ..setFloat(6, colors[1].r)
      ..setFloat(7, colors[1].g)
      ..setFloat(8, colors[1].b)
      ..setFloat(9, colors[2].r)
      ..setFloat(10, colors[2].g)
      ..setFloat(11, colors[2].b);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.time != time || !listEquals(old.colors, colors);
}

/// FALLBACK sin shader: manchas de acuarela sobre negro.
class _WatercolorPainter extends CustomPainter {
  final double t;
  final List<Color> colors;

  _WatercolorPainter({required this.t, required this.colors});

  /// Anclas normalizadas de las manchas: repartidas por bordes/esquinas,
  /// lejos del carril central donde van artwork + lyrics.
  static const _anchors = <(double, double)>[
    (0.14, 0.24),
    (0.86, 0.18),
    (0.80, 0.84),
    (0.16, 0.86),
    (0.52, 0.06),
    (0.48, 0.96),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Base negra pura: el contraste de las letras manda.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF050505),
    );

    final r = size.shortestSide;
    var k = 0;
    for (var i = 0; i < colors.length; i++) {
      // Desaturar hacia negro un 30%: el color se siente sin pelear con
      // el texto.
      final c = Color.lerp(colors[i], Colors.black, 0.30)!;
      // Velocidades ENTERAS en múltiplos del ciclo de `t` (y armónico 2×):
      // al repetir el controller el fondo retoma su fase exacta → loop
      // infinito sin saltos.
      final speed = i.isEven ? 1.0 : 2.0;
      for (var j = 0; j < 2; j++, k++) {
        final (ax, ay) = _anchors[k % _anchors.length];
        final ph = k * 2.39996; // ángulo áureo: derivas desincronizadas
        final cx = size.width * ax + r * 0.10 * math.sin(t * speed + ph);
        final cy = size.height * ay + r * 0.07 * math.cos(t * speed * 2 - ph);
        _wash(
          canvas,
          Offset(cx, cy),
          r * (j == 0 ? 0.46 : 0.60),
          c.withValues(alpha: j == 0 ? 0.20 : 0.11),
        );
      }
    }

    // Sin viñeta: el fluido cubre TODO el lienzo borde a borde.
  }

  /// Una mancha de acuarela: tres círculos radiales superpuestos con
  /// desfase — el solape irregular simula el borde orgánico de la acuarela
  /// sin necesidad de blur (cada radial ya trae su caída difusa).
  void _wash(Canvas canvas, Offset center, double r, Color color) {
    void circle(Offset off, double radius, Color col) {
      final c = center + off;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              col,
              col.withValues(alpha: col.a * 0.45),
              col.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }

    circle(Offset.zero, r, color);
    circle(
      Offset(r * 0.55, -r * 0.34),
      r * 0.72,
      color.withValues(alpha: color.a * 0.7),
    );
    circle(
      Offset(-r * 0.48, r * 0.42),
      r * 0.66,
      color.withValues(alpha: color.a * 0.6),
    );
  }

  @override
  bool shouldRepaint(_WatercolorPainter old) =>
      old.t != t || !listEquals(old.colors, colors);
}

// ── Contenedor flotante de controles ──────────────────────────────────────

/// Píldora glass con el transporte, posicionada bajo el artwork EN EL STACK
/// RAÍZ (hit-test garantizado). Hover PROPIO: aparece al entrar el cursor
/// en su zona y se oculta con retardo al salir.
class _FloatingControls extends StatefulWidget {
  const _FloatingControls();

  @override
  State<_FloatingControls> createState() => _FloatingControlsState();
}

class _FloatingControlsState extends State<_FloatingControls> {
  bool _hovered = false;
  Timer? _hideTimer;

  void _show() {
    _hideTimer?.cancel();
    if (!_hovered) setState(() => _hovered = true);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _hovered = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _show(),
      onExit: (_) => _scheduleHide(),
      child: AnimatedOpacity(
        opacity: _hovered ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        // SIN contenedor: botones sueltos sobre el fondo.
        child: const _TransportControls(),
      ),
    );
  }
}

// ── Columna izquierda: artwork ────────────────────────────────────────────

class _LeftColumn extends StatelessWidget {
  final double artSide;
  final Track? track;

  /// Ruta del archivo de artwork en disco (null mientras carga).
  final String? artPath;

  const _LeftColumn({
    required this.artSide,
    required this.track,
    required this.artPath,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Artwork(
      artSide: artSide,
      artPath: artPath,
      fallback: Container(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Icon(
          Icons.music_note_rounded,
          size: artSide / 4,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Portada con detalle de PAUSA: al pausar hace un scale-down sutil
/// (0.955) con animación suave; al reproducir vuelve a 1.0.
class _Artwork extends StatefulWidget {
  final double artSide;
  final String? artPath;
  final Widget fallback;

  const _Artwork({
    required this.artSide,
    required this.artPath,
    required this.fallback,
  });

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  late bool _playing = context.read<PlayerService>().isPlaying;
  StreamSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    _playingSub = context.read<PlayerService>().playing.listen((p) {
      if (mounted && p != _playing) setState(() => _playing = p);
    });
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sin AnimatedSwitcher: el crossfade forzaba decodificar 2 imágenes
    // en GPU simultáneamente. Swap directo + scale de pausa.
    return SizedBox(
      width: widget.artSide,
      height: widget.artSide,
      child: AnimatedScale(
        scale: _playing ? 1.0 : 0.955,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: widget.artSide,
            height: widget.artSide,
            child: widget.artPath != null
                ? Image.file(
                    File(widget.artPath!),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    cacheWidth: widget.artSide.round(),
                  )
                : widget.fallback,
          ),
        ),
      ),
    );
  }
}

/// Controles de transporte + progreso bajo el artwork grande. Los modos
/// (shuffle/repeat/preparando) son ValueNotifiers del player; posición/
/// duración/playing llegan por stream con throttle propio.
class _TransportControls extends StatefulWidget {
  const _TransportControls();

  @override
  State<_TransportControls> createState() => _TransportControlsState();
}

class _TransportControlsState extends State<_TransportControls> {
  double? _dragValue;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<bool>? _playingSub;
  DateTime _lastPosFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _position = player.positionValue;
    _total = player.durationValue ?? Duration.zero;
    _playing = player.isPlaying;
    _posSub = player.position.listen((p) {
      // Throttle ~250ms: mismo criterio que el player bar.
      final now = DateTime.now();
      if (!mounted ||
          (p != Duration.zero &&
              now.difference(_lastPosFrame) <
                  const Duration(milliseconds: 250))) {
        return;
      }
      _lastPosFrame = now;
      setState(() => _position = p);
    });
    _durSub = player.duration.listen((d) {
      if (mounted) setState(() => _total = d ?? Duration.zero);
    });
    _playingSub = player.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, ' ');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final l10n = AppLocalizations.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = context.read<ThemeController>().seededPrimary;
    final progress = _total.inMilliseconds > 0
        ? (_position.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final shown = _dragValue ?? progress;

    return Column(
      children: [
        // Transporte IDÉNTICO al player bar: fila COMPACTA centrada
        // (shuffle | prev | play | next | repeat), no repartida a los
        // bordes. Escalado ~1.4× para la distancia del fullscreen.
        ValueListenableBuilder<String?>(
          valueListenable: player.preparingTrackId,
          builder: (context, preparingId, _) {
            final preparing = preparingId != null;
            const iconSize = 26.0;
            const btnConstraints = BoxConstraints.tightFor(
              width: 46,
              height: 52,
            );

            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Shuffle (se enciende con el acento cuando está activo).
                ValueListenableBuilder<bool>(
                  valueListenable: player.shuffle,
                  builder: (context, on, _) => IconButton(
                    icon: Icon(Icons.shuffle_rounded, size: iconSize),
                    constraints: btnConstraints,
                    padding: EdgeInsets.zero,
                    color: on ? accent : muted,
                    tooltip: on ? l10n.shuffleOn : l10n.shuffle,
                    onPressed: player.toggleShuffle,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  constraints: btnConstraints,
                  padding: EdgeInsets.zero,
                  color: accent,
                  tooltip: l10n.previous,
                  onPressed: player.previous,
                ),
                // Play / Pausa (o loader) con footprint fijo.
                SizedBox(
                  width: 60,
                  height: 52,
                  child: Center(
                    child: preparing
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : IconButton(
                            iconSize: 52,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 56,
                              height: 52,
                            ),
                            icon: Icon(
                              _playing
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              color: accent,
                            ),
                            tooltip: _playing ? l10n.pause : l10n.play,
                            onPressed: player.togglePlayPause,
                          ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  constraints: btnConstraints,
                  padding: EdgeInsets.zero,
                  color: accent,
                  tooltip: l10n.next,
                  onPressed: player.next,
                ),
                ValueListenableBuilder<LoopMode>(
                  valueListenable: player.repeatMode,
                  builder: (context, mode, _) => IconButton(
                    icon: Icon(
                      mode == LoopMode.one
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      size: iconSize,
                    ),
                    constraints: btnConstraints,
                    padding: EdgeInsets.zero,
                    color: mode != LoopMode.off ? accent : muted,
                    tooltip: switch (mode) {
                      LoopMode.off => l10n.repeatOff,
                      LoopMode.all => l10n.repeatAll,
                      LoopMode.one => l10n.repeatOne,
                    },
                    onPressed: player.toggleRepeat,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              _fmt(_total * shown),
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: SliderTheme(
                // MISMA barra que el player bar: línea fina sin pulgar.
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                  showValueIndicator: ShowValueIndicator.never,
                  activeTrackColor: accent,
                ),
                child: Slider(
                  value: shown,
                  onChanged: _total.inMilliseconds > 0
                      ? (v) => setState(() => _dragValue = v)
                      : null,
                  onChangeEnd: _total.inMilliseconds > 0
                      ? (v) {
                          player.seek(_total * v);
                          setState(() => _dragValue = null);
                        }
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Text(
              _fmt(_total),
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Cabecera central ──────────────────────────────────────────────────────

class _CenterHeader extends StatelessWidget {
  final Track? track;

  const _CenterHeader({required this.track});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final midWidth = MediaQuery.sizeOf(context).width * 0.32;
    return Padding(
      padding: const EdgeInsets.only(top: 44),
      child: SizedBox(
        width: midWidth,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.15),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey(track?.id),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track?.title ?? '',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  track?.artist ?? '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
