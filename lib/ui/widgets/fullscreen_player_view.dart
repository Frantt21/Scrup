import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, Uint8List;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';

/// Modo pantalla completa "dedicado": el reproductor ES la app.
///
/// Layout (todo cubre la ventana):
/// - Fondo animado con TRES colores extraídos del artwork actual (blobs
///   radiales suaves que derivan lentamente; uso de GPU asumido porque el
///   modo es para sesión dedicada).
/// - Izquierda: artwork GRANDE con los controles debajo.
/// - Centro arriba: título + artista.
/// - Derecha: lyrics completos (la misma vista del app, reparentada por el
///   shell vía GlobalKey: cero re-fetch y un solo ticker).
///
/// Entrada/salida ANIMADA tipo "contenedores flotantes": cada bloque entra
/// deslizándose desde su borde (izquierda ←, derecha →, centro desde arriba)
/// y al salir se retira hacia SU lado, revelando la UI normal debajo.
class FullscreenPlayerView extends StatefulWidget {
  /// `true` mientras el modo esté activo. Al pasar a `false` el overlay
  /// reproduce la salida y avisa con [onExited].
  final bool active;

  /// Panel de lyrics (instancia del shell reparentada con GlobalKey).
  final Widget lyricsPanel;

  /// El botón X pide cerrar (el shell decide: sale del fullscreen nativo).
  final VoidCallback onRequestClose;

  /// La animación de salida terminó: el shell puede desmontar el overlay.
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
  /// Entrada/salida del overlay completo.
  late final AnimationController _transition;

  /// Deriva lenta de los blobs de fondo (loop continuo).
  late final AnimationController _drift;

  Track? _track;

  /// PlayerService (para listeners de cola y streams).
  late final PlayerService _player;

  /// Paleta TRÍO del artwork actual para el fondo.
  List<Color> _palette = const [];

  /// Bytes del artwork ACTUAL (máxima resolución) para pintar la portada.
  Uint8List? _artBytes;

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
    // Si nace ya activo (arranque directo en modo), animar la entrada.
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _transition.forward();
      });
    }
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _trackSub = _player.currentTrack.listen((t) {
      if (!mounted || t?.id == _track?.id) return;
      setState(() => _track = t);
      _loadTrackVisuals(t);
    });
    // Precarga al moverse la cola también (no solo tras cada carga).
    _player.queueIndex.addListener(_prefetchNextListener);
    _player.queue.addListener(_prefetchNextListener);
    _loadTrackVisuals(_track);
  }

  void _prefetchNextListener() => unawaited(_prefetchNext());

  void _onTransitionStatus(AnimationStatus status) {
    // Salida completa y ya NO activo → avisar al shell para desmontarnos.
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
    _player.queueIndex.removeListener(_prefetchNextListener);
    _player.queue.removeListener(_prefetchNextListener);
    _transition.dispose();
    _drift.dispose();
    super.dispose();
  }

  // ── Artwork hi-res + paleta (una sola descarga, con precarga) ────────────

  /// Bytes de artworks ya descargados esta sesión (clave: URL original).
  static final Map<String, Uint8List> _artBytesCache = {};

  /// Tríos de color ya calculados (clave: URL original).
  static final Map<String, List<Color>> _trioCache = {};

  /// Asegura bytes hi-res + trío para una URL. Idempotente y seguro de
  /// llamar en paralelo: sirve tanto al track actual como a la PRECARGA
  /// del siguiente (así el cambio de canción no tiene intermedios).
  Future<(Uint8List?, List<Color>)> _ensureVisuals(String rawUrl) async {
    var bytes = _artBytesCache[rawUrl];
    var trio = _trioCache[rawUrl];
    if (bytes != null && trio != null) return (bytes, trio);

    if (bytes == null) {
      // Artwork LOCAL (portada propia desde metadatos): leer del disco.
      final lower = rawUrl.toLowerCase();
      if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        try {
          final f = File(rawUrl);
          if (await f.exists()) {
            final b = await f.readAsBytes();
            if (b.length > 128) bytes = b;
          }
        } catch (_) {
          // Archivo ilegible → sin artwork.
        }
        if (bytes != null) _artBytesCache[rawUrl] = bytes;
      }
    }
    if (bytes == null) {
      // Red: cadena de respaldo maxresdefault (1280px) → URL original.
      for (final url in [Track.hiResThumbnail(rawUrl) ?? rawUrl, rawUrl]) {
        try {
          final resp = await http
              .get(
                Uri.parse(url),
                headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
              )
              .timeout(const Duration(seconds: 10));
          // >1KB: descarta placeholders grises de YouTube (404 disfrazado).
          if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
            bytes = resp.bodyBytes;
            break;
          }
        } catch (_) {
          // Siguiente eslabón.
        }
      }
      if (bytes != null) _artBytesCache[rawUrl] = bytes;
    }
    if (bytes == null) return (null, const <Color>[]);

    if (trio == null) {
      try {
        final palette = await PaletteGenerator.fromImageProvider(
          MemoryImage(bytes),
          maximumColorCount: 16,
        );
        trio = _pickTrio(palette);
      } catch (_) {
        trio = const [];
      }
      _trioCache[rawUrl] = trio;
    }
    return (bytes, trio);
  }

  Future<void> _loadTrackVisuals(Track? track) async {
    final token = ++_visualToken;
    final rawUrl = track?.thumbnailUrl;
    if (rawUrl == null || rawUrl.isEmpty) {
      if (mounted) {
        setState(() {
          _artBytes = null;
          _palette = const [];
        });
      }
      return;
    }

    final (bytes, colors) = await _ensureVisuals(rawUrl);
    if (!mounted || token != _visualToken) return;
    setState(() {
      _artBytes = bytes;
      _palette = colors;
    });
    unawaited(_prefetchNext());
  }

  /// Precarga bytes+paleta del SIGUIENTE track de la cola: cuando cambie la
  /// canción todo está listo y la transición es inmediata.
  Future<void> _prefetchNext() async {
    if (!mounted) return;
    final player = context.read<PlayerService>();
    final q = player.queue.value;
    final i = player.queueIndex.value + 1;
    if (i < 0 || i >= q.length) return;
    final url = q[i].thumbnailUrl;
    if (url == null ||
        url.isEmpty ||
        (_artBytesCache.containsKey(url) && _trioCache.containsKey(url))) {
      return;
    }
    await _ensureVisuals(url);
  }

  /// Tres colores diferenciados: prioriza vivaces y exige distancia de tono
  /// entre elegidos; si la imagen es monocroma, deriva variaciones de
  /// luminancia del dominante (criterio coherente con ThemeController).
  static List<Color> _pickTrio(PaletteGenerator palette) {
    double score(Color c) {
      final hsl = HSLColor.fromColor(c);
      return hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 2);
    }

    final swatches = <Color>[for (final c in palette.paletteColors) c.color]
      ..sort((a, b) => score(b).compareTo(score(a)));
    if (swatches.isEmpty) return const [];

    double hueOf(Color c) => HSLColor.fromColor(c).hue;
    bool sat(Color c) => HSLColor.fromColor(c).saturation >= 0.15;

    final picked = <Color>[swatches.first];
    for (final c in swatches.skip(1)) {
      if (picked.length >= 3) break;
      // Distancia de tono SOLO entre colores con saturación real: dos grises
      // comparten "hue" pero son compatibles como blobs distintos.
      final farEnough = picked.every((p) {
        if (!sat(p) || !sat(c)) return true;
        final d = (hueOf(p) - hueOf(c)).abs() % 360;
        return math.min(d, 360 - d) >= 25;
      });
      if (farEnough) picked.add(c);
    }
    // Relleno por luminancia si faltaron matices distintos (monocromos).
    while (picked.length < 3) {
      final base = HSLColor.fromColor(picked.first);
      final shift = picked.length == 1 ? 0.22 : -0.18;
      picked.add(
        base
            .withLightness((base.lightness + shift).clamp(0.08, 0.85))
            .toColor(),
      );
    }
    return picked;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.read<ThemeController>().seededPrimary;
    final palette = _palette.isEmpty
        ? [accent, accent.withValues(alpha: 0.65), kDefaultAccent]
        : _palette;

    return AnimatedBuilder(
      animation: _transition,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_transition.value);
        return Material(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Fondo animado tricolor (aparece con fade).
              Opacity(
                opacity: t,
                child: RepaintBoundary(
                  child: _AnimatedBackdrop(drift: _drift, colors: palette),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  // Contenedor ÚNICO centrado (no justificado): artwork +
                  // controles a la izquierda, GAP, lyrics a la derecha.
                  final artSide = math
                      .min(size.height - 250, 620.0)
                      .clamp(240.0, 720.0);
                  const gap = 56.0;
                  var lyricsW = (size.width * 0.36).clamp(340.0, 660.0);
                  if (artSide + gap + lyricsW > size.width - 96) {
                    lyricsW = math.max(280.0, size.width - 96 - artSide - gap);
                  }
                  // Geometría del bloque centrado (para posicionar el
                  // contenedor de controles en el STACK RAÍZ: los eventos
                  // de ratón no se entregan fuera de los bounds del padre,
                  // así que la zona DEBE vivir en un stack full-screen).
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
                            // Izquierda (sale ← al cerrar).
                            FractionalTranslation(
                              translation: Offset(-(1 - t), 0),
                              child: Opacity(
                                opacity: t,
                                child: _LeftColumn(
                                  artSide: artSide,
                                  track: _track,
                                  bytes: _artBytes,
                                ),
                              ),
                            ),
                            const SizedBox(width: gap),
                            // Derecha (sale → al cerrar): lyrics embebidos.
                            // Altura LIMITADA (acompaña al artwork, no todo
                            // el alto de la pantalla).
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
                      // Contenedor FLOTANTE de controles: posición relativa
                      // al artwork pero EN EL STACK RAÍZ → hit-test real.
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
              // Centro arriba: título + artista (sale ↑).
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
              // Botón cerrar (fade).
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

/// Olas VERTICALES que cubren TODO el fondo: cada color es una banda cuyo
/// borde ondula en función de la altura y deriva con el tiempo; se pintan
/// solapadas hacia la derecha sobre una base del primer color, así el lienzo
/// completo queda tapado siempre. Un blur generoso funde los bordes.
///
/// El loop es INFINITO y sin costuras (coeficientes temporales enteros) y
/// los colores se interpolan exponencialmente frame a frame, así que al
/// cambiar de canción el fondo MUTA suavemente en vez de saltar.
class _AnimatedBackdrop extends StatefulWidget {
  final Animation<double> drift;
  final List<Color> colors;

  const _AnimatedBackdrop({required this.drift, required this.colors});

  @override
  State<_AnimatedBackdrop> createState() => _AnimatedBackdropState();
}

class _AnimatedBackdropState extends State<_AnimatedBackdrop>
    with SingleTickerProviderStateMixin {
  /// Transición de paleta (mismo criterio que el gradiente del player bar):
  /// al cambiar de canción se anima del trío mostrado al nuevo en ~700ms.
  late final AnimationController _fade;

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
  }

  @override
  void didUpdateWidget(_AnimatedBackdrop old) {
    super.didUpdateWidget(old);
    final next = _padded(widget.colors);
    if (!listEquals(next, _target)) {
      // El ORIGEN es lo que se está viendo ahora mismo (interpolado hasta
      // el punto de corte), así el cambio nunca salta ni "congela" mezclas.
      _from = _shown();
      _target = next;
      _fade.forward(from: 0);
    }
  }

  List<Color> _padded(List<Color> src) => [
    for (var i = 0; i < 3; i++) i < src.length ? src[i] : kDefaultAccent,
  ];

  /// Colores mostrados ahora mismo (lerp curvado origen→destino).
  List<Color> _shown() {
    final t = Curves.easeOutCubic.transform(_fade.value);
    return [for (var i = 0; i < 3; i++) Color.lerp(_from[i], _target[i], t)!];
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF060606),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.drift, _fade]),
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _WavePainter(
              t: widget.drift.value * 2 * math.pi,
              colors: _shown(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }
}

class _WavePainter extends CustomPainter {
  final double t;
  final List<Color> colors;

  _WavePainter({required this.t, required this.colors});

  Color _darken(Color c, double factor) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness * factor).clamp(0.02, 1)).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Base: primer color oscurecido, cobertura total garantizada.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = _darken(colors.first, 0.45),
    );

    final blur = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 46);

    for (var i = 0; i < colors.length; i++) {
      final c = colors[i];
      final baseX = size.width * (0.16 + 0.34 * i);
      final amp = size.width * (0.055 + 0.02 * i);
      // Velocidades ENTERAS en múltiplos del ciclo de `t`: al repetir el
      // controller (t: 0→2π) las ondas retoman exactamente su fase, así el
      // loop es infinito sin saltos.
      final speed = i.isEven ? 1.0 : 2.0;
      final phase = i * 2.4;
      final freq = 2 * math.pi / size.height * (1.4 + 0.5 * i);

      final path = Path()..moveTo(baseX, -60);
      const step = 28.0;
      for (var y = -60.0; y <= size.height + 60; y += step) {
        // Armónico con múltiplo entero (2×) de la velocidad: también
        // continuo en la envoltura del ciclo.
        final x =
            baseX +
            amp * math.sin(y * freq + t * speed + phase) +
            amp * 0.4 * math.sin(y * freq * 0.53 - t * speed * 2);
        path.lineTo(x, y);
      }
      // Rellena hasta el borde derecho: la ola CUBRE lo que queda a su lado.
      path.lineTo(size.width + 80, size.height + 80);
      path.lineTo(size.width + 80, -60);
      path.close();

      final shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          c.withValues(alpha: 0.88),
          _darken(c, 0.62).withValues(alpha: 0.92),
        ],
      ).createShader(Offset.zero & size);

      canvas.drawPath(path, blur..shader = shader);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
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

  /// Bytes hi-res de la portada (null mientras cargan).
  final Uint8List? bytes;

  const _LeftColumn({
    required this.artSide,
    required this.track,
    required this.bytes,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // SOLO artwork: crossfade cuando llegan píxeles nuevos (key por bytes),
    // sin estado vacío entre canciones. Los controles viven aparte, en el
    // contenedor flotante del stack raíz.
    return _Artwork(
      artSide: artSide,
      bytes: bytes,
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
  final Uint8List? bytes;
  final Widget fallback;

  const _Artwork({
    required this.artSide,
    required this.bytes,
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
    return AnimatedScale(
      scale: _playing ? 1.0 : 0.955,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: widget.artSide,
          height: widget.artSide,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween(begin: 0.94, end: 1.0).animate(anim),
                child: child,
              ),
            ),
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [...previousChildren, ?currentChild],
            ),
            child: widget.bytes != null
                ? KeyedSubtree(
                    key: ValueKey(widget.bytes),
                    child: Image.memory(
                      widget.bytes!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.high,
                    ),
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
