import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../core/app_log.dart';
import '../../data/database.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/player_service.dart';
import '../playlist_actions.dart';
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
///   playlist/favorito centrados verticalmente y línea de progreso).
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

  /// Notifica a la app cuando se abre/cierra el sheet de letras (para que
  /// bloquee el tap/arrastre del panel expandido mientras está abierto).
  final ValueChanged<bool>? onLyricsOpenChanged;

  const MobilePlayerOverlay({
    super.key,
    required this.height,
    required this.percentage,
    required this.onOpenQueue,
    required this.onClose,
    this.onLyricsOpenChanged,
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
  // Último acento/track logueado (el build corre en cada frame del morph;
  // solo se loguea el CAMBIO para no inundar logcat).
  Color? _lastLoggedAccent;
  String? _lastLoggedTrackId;

  /// Superficie neutra pre-acento: funde desde negro, nunca lila.
  static const Color _kIdleSurface = Colors.transparent;
  bool _dragging = false;
  double _dragValue = 0;
  bool _lyricsOpen = false;
  // Animación del artwork al cambiar de canción. `_slideDir` = lado desde
  // el que ENTRA el arte nuevo: +1 = desde la DERECHA (siguiente), -1 =
  // desde la IZQUIERDA (anterior), 0 = sin desplazamiento (solo fundido;
  // cambios automáticos o por selección en la cola). `_pendingSlide` guarda
  // la dirección pedida por el botón/gesto y se consume cuando llega la
  // pista nueva (así la animación depende de la ACCIÓN, no de la posición
  // en la cola).
  double _slideDir = 0;
  double _pendingSlide = 0;

  /// Cuándo se pidió la dirección (para no aplicar un slide rancio si el
  /// tap fue tragado por el debounce del servicio).
  DateTime? _pendingSlideAt;

  /// La dirección solo vale si el cambio llega justo tras el gesto; si el
  /// tap se ignoró (debounce) y el cambio vino de otro lado, fundido.
  bool get _slideFresh {
    final at = _pendingSlideAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(milliseconds: 1500);
  }

  // Corazón del doble toque: burst en el punto del toque sobre el artwork.
  int _heartBurst = 0;
  Offset _heartBurstPos = Offset.zero;
  final GlobalKey _artStackKey = GlobalKey();

  // Prefetch de artworks de la cola (como desktop): descarga a disco y
  // precachea las portadas de las próximas pistas para que al cambiar de
  // canción el arte nuevo aparezca AL INSTANTE — sin placeholder ni decode
  // en caliente (que es lo que provocaba las pérdidas de frame al cambiar
  // de pista).
  final Set<String> _ensuredArtworkUrls = {};

  // Favoritos (misma lógica que desktop/player_bar.dart):
  int _favoritesId = -1;
  bool _isFavorite = false;
  StreamSubscription<bool>? _favSub;

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
        // Consume la dirección pedida por el usuario (siguiente/anterior);
        // los cambios automáticos quedan en 0 (solo fundido).
        _slideDir = _slideFresh ? _pendingSlide : 0;
        _pendingSlide = 0;
        _pendingSlideAt = null;
        setState(() => _track = t);
        _refreshFavoriteState();
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
      // NOTA: sin listener de posición aquí a propósito. El _ticker de 500ms
      // (`if (pos != _pos)`) ya refresca `_pos` para la barra/tiempos: un
      // setState en CADA evento del stream (4Hz, incluso en pausa con el
      // mismo valor) reconstruía todo el overlay sin parar y amplificaba
      // cada transición. Ver SCPR[JANK].
      _player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _dur = d);
      }),
    ]);
    _player.preparingTrackId.addListener(_onPreparing);
    _player.queue.addListener(_onQueueChanged);
    _player.queueIndex.addListener(_onQueueChanged);
    _onPreparing();
    if (_playing) _ticker = _startTicker();
    unawaited(_setupFavorites(context.read<AppDatabase>()));
  }

  Future<void> _setupFavorites(AppDatabase db) async {
    final id = await db.ensureFavoritesPlaylist();
    if (!mounted) return;
    _favoritesId = id;
    final track = _track;
    if (track == null) return;
    _favSub = db.watchTrackInPlaylist(id, track.id).listen((inside) {
      if (!mounted) return;
      // Sin setState redundante: la mayoría de cambios de canción conservan
      // el estado de favorito y reconstruir todo el overlay para nada quemaba
      // frames en cada transición.
      if (inside == _isFavorite) return;
      setState(() => _isFavorite = inside);
    });
  }

  void _refreshFavoriteState() {
    if (_favoritesId < 0) return;
    final track = _track;
    final db = context.read<AppDatabase>();
    _favSub?.cancel();
    if (!mounted) return;
    setState(() => _isFavorite = false);
    if (track == null) return;
    _favSub = db.watchTrackInPlaylist(_favoritesId, track.id).listen((inside) {
      if (!mounted) return;
      if (inside == _isFavorite) return;
      setState(() => _isFavorite = inside);
    });
  }

  void _onQueueChanged() => unawaited(_prefetchArtworks());

  /// Cuántas portadas siguientes se precargan (las primeras siempre primero:
  /// el bucle es SECUENCIAL, la 1ª termina antes de empezar la 2ª, así no
  /// hay 5 descargas simultáneas compitiendo con el audio ni saturando la
  /// red).
  static const int _artPrefetchAhead = 5;

  /// Descarga + precachea las portadas de las próximas pistas de la cola
  /// (máx. [_artPrefetchAhead]), igual que hace el player de desktop. Las
  /// URLs usan la MISMA clave (hi-res) que el `CoverImage` del overlay para
  /// que el arte nuevo salga del caché al instante.
  Future<void> _prefetchArtworks() async {
    // EXPERIMENTO kNoArtwork: sin descargas ni precaches de portadas.
    if (kNoArtwork || !mounted) return;
    final q = _player.queue.value;
    final start = _player.queueIndex.value + 1;
    if (start < 0 || start >= q.length) return;
    final cache = context.read<ArtworkCacheService>();
    for (
      var offset = 0;
      offset < _artPrefetchAhead && start + offset < q.length;
      offset++
    ) {
      final raw = q[start + offset].thumbnailUrl;
      if (raw == null || raw.isEmpty) continue;
      final url = Track.hiResThumbnail(raw) ?? raw;
      if (_ensuredArtworkUrls.contains(url)) continue;
      _ensuredArtworkUrls.add(url);
      await _ensureArtwork(url, cache);
    }
  }

  Future<void> _ensureArtwork(String url, ArtworkCacheService cache) async {
    try {
      var path = await cache.filePathFor(url);
      if (path == null) {
        // No está en disco: descárgalo (hi-res con fallback a la original).
        for (final dlUrl in [Track.hiResThumbnail(url) ?? url, url]) {
          try {
            final resp = await http
                .get(
                  Uri.parse(dlUrl),
                  headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
                )
                .timeout(const Duration(seconds: 10));
            if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
              await cache.save(url, resp.bodyBytes);
              path = await cache.filePathFor(url);
              break;
            }
          } catch (_) {}
        }
      }
      if (!mounted || path == null) return;
      // Precachea en el image cache de Flutter: al cambiar de canción el
      // decode ya está hecho y el arte aparece sin cortes. OJO: con el MISMO
      // tamaño que el display (`cacheWidth: 900` del artwork compartido); con
      // otra clave el precache no sirve y se decodifica en la transición.
      try {
        await precacheImage(
          ResizeImage(FileImage(File(path)), width: 900),
          context,
        );
      } catch (_) {}
    } catch (_) {}
  }

  /// Siguiente / anterior CON animación dirigida del artwork: siguiente
  /// entra desde la derecha (+1), anterior desde la izquierda (-1).
  void _goNext() {
    _pendingSlide = 1;
    _pendingSlideAt = DateTime.now();
    _player.next();
  }

  void _goPrev() {
    _pendingSlide = -1;
    _pendingSlideAt = DateTime.now();
    _player.previous();
  }

  /// Arma el corazón del doble toque en el punto exacto del toque (coords
  /// locales del artwork).
  void _armHeartBurst(Offset globalPos) {
    final box = _artStackKey.currentContext?.findRenderObject();
    Offset local;
    if (box is RenderBox) {
      local = box.globalToLocal(globalPos);
    } else {
      local = const Offset(0, 0);
    }
    setState(() {
      _heartBurstPos = local;
      _heartBurst++;
    });
  }

  Future<void> _toggleFavorite() async {
    final track = _track;
    if (track == null || _favoritesId < 0) return;
    final db = context.read<AppDatabase>();
    if (_isFavorite) {
      await db.removeFromPlaylist(_favoritesId, track.id);
    } else {
      await db.addToPlaylist(_favoritesId, track);
    }
  }

  void _setLyricsOpen(bool v) {
    if (_lyricsOpen == v) return;
    setState(() => _lyricsOpen = v);
    widget.onLyricsOpenChanged?.call(v);
  }

  void _onPreparing() {
    final id = _player.preparingTrackId.value;
    appLog('PREP', 'overlay id=${shortId(id)} active=$_preparingActive');
    // Consume la dirección del usuario ANTES de que el artwork cambie al
    // track que se está preparando (así la animación sale con el gesto). Si
    // la preparación se CANCELA (id null tras una preparación activa), se
    // vuelve al arte anterior con solo fundido (sin slide "fantasma").
    if (id != null) {
      _slideDir = _slideFresh ? _pendingSlide : 0;
      _pendingSlide = 0;
      _pendingSlideAt = null;
    } else if (_preparingActive) {
      _slideDir = 0;
    }
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
    // La pista entrante ya se conoce: se precarga su acento (y artwork) en
    // paralelo a la carga del audio, para que al publicarse la pista el
    // color esté en caché y la transición no pase por el lila por defecto.
    final incoming = _preparing;
    if (incoming != null) {
      context.read<ThemeController>().warmAccent(incoming.thumbnailUrl);
    }
  }

  Timer? _startTicker() {
    return Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _dragging) return;
      final pos = _player.positionValue;
      // Solo reconstruye al cambiar de SEGUNDO (los labels van a segundos y
      // la barra a 1Hz es indistinguible): reconstruir el overlay completo
      // 2×/seg solo por el progreso quemaba frames en cada transición.
      if (pos.inSeconds != _pos.inSeconds || pos < _pos) {
        setState(() => _pos = pos);
      }
    });
  }

  @override
  void dispose() {
    _player.preparingTrackId.removeListener(_onPreparing);
    _player.queue.removeListener(_onQueueChanged);
    _player.queueIndex.removeListener(_onQueueChanged);
    _favSub?.cancel();
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
    countBuild('overlay');
    final buildSw = Stopwatch()..start();
    final theme = Theme.of(context);
    final themeController = context.watch<ThemeController>();
    // Sin acento todavía (arranque en frío / sin pista): neutro en vez del
    // lila del tema — el fondo funde desde negro al primer color real y el
    // lila por defecto jamás aparece en una transición.
    final accent =
        themeController.accentColor ?? _kIdleSurface;
    final cs = theme.colorScheme;

    final track = _track;
    // Mientras se PREPARA la pista siguiente (next/prev), el artwork ya
    // cambia a la nueva: la animación de desplazamiento arranca al pulsar el
    // botón/gesto y no espera a que la pista termine de cargar (se sentía
    // lageada). Cuando no hay preparación en curso, muestra la pista actual.
    final Track? showing = _preparingActive && _preparing != null
        ? _preparing
        : track;
    if (_lastLoggedAccent != accent || _lastLoggedTrackId != showing?.id) {
      appLog(
        'UI',
        'overlay accent=${colorHex(accent)} '
        'showing=${shortId(showing?.id)} themePrimary=${colorHex(theme.colorScheme.primary)}',
      );
      _lastLoggedAccent = accent;
      _lastLoggedTrackId = showing?.id;
    }
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
    // Composición vertical del expandido:
    //   header (status + 52) → artwork → gap → bloque de controles → sheet.
    // El artwork es grande (0.88 × ancho) y la composición completa
    // (arte + bloque) queda CENTRADA entre el header y el sheet de letras
    // cerrado: así no queda un hueco enorme arriba ni el contenido pegado
    // al fondo.
    final double topPad = MediaQuery.paddingOf(context).top;
    final double headerH = topPad + 52.0;
    const double artContentGap = 24.0;
    // Alturas estimadas del bloque bajo el arte (título + barra + tiempos +
    // transporte ≈ 200dp) y del sheet de letras cerrado (≈ 60dp sobre el
    // borde inferior). Se usan solo para repartir el espacio sobrante.
    const double contentEst = 200.0;
    const double lyricsPeekEst = 60.0;
    final double maxSide =
        (fullH - headerH - artContentGap - contentEst - lyricsPeekEst).clamp(
          120.0,
          double.infinity,
        );
    final double artSide = (w * 0.88).clamp(120.0, maxSide);
    final double artLeft = (w - artSide) / 2;
    // Margen superior que reparte por igual el espacio sobrante entre el
    // header y el sheet (acotado para nunca dejar al arte pegado al header).
    final double topSlack =
        ((fullH -
                    headerH -
                    artSide -
                    artContentGap -
                    contentEst -
                    lyricsPeekEst) /
                2)
            .clamp(8.0, 160.0);
    final double artTop = headerH + topSlack;

    // Fondo plano de acento con crossfade RGB al cambiar de pista (sin
    // tercer color intermedio). El contenido vive como `child` y NO se
    // reconstruye en cada frame de la animación.
    final Widget page = _AccentBackground(
      color: accent,
      child: Material(
        type: MaterialType.transparency,
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
              playing: _playing,
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
                            // Progreso: línea fina en la base, DETRÁS de todo.
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor:
                                    _dur != null && _dur!.inMilliseconds > 0
                                    ? (_pos.inMilliseconds /
                                              _dur!.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                    : 0.0,
                                child: Container(
                                  height: 3,
                                  color: Colors.black.withValues(alpha: 0.35),
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
                    // Muestra la pista que se está preparando (igual que el
                    // artwork): el bloque acompaña a la animación del arte.
                    track: showing,
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
          ],
        ),
      ),
    );
    final ms = buildSw.elapsedMilliseconds;
    if (ms >= kBuildWatchdogMs) {
      appLog('PERF', 'overlay build ${ms}ms track=${shortId(_track?.id)}');
    }
    return page;
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
    required bool playing,
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
      // Al pausar el artwork se encoge un poco. El ESCALADO es del contenedor
      // (ClipRRect), no de la imagen: así los bordes redondeados escalan con
      // el contenedor y no se pierden al encoger el arte.
      child: AnimatedScale(
        scale: playing ? 1.0 : 0.93,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        // Doble toque: like / quitar like (+ corazón animado en el punto
        // del toque). Deslizar horizontal: siguiente / anterior. La
        // dirección la piden _goNext/_goPrev (mismos que los botones del
        // transporte): siguiente entra por la DERECHA, anterior por la
        // IZQUIERDA.
        child: GestureDetector(
          onDoubleTapDown: (d) => _armHeartBurst(d.globalPosition),
          onDoubleTap: _toggleFavorite,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -350) {
              _goNext();
            } else if (v > 350) {
              _goPrev();
            }
          },
          child: Stack(
            key: _artStackKey,
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  // El arte que ENTRA viene del lado de _slideDir (+1 =
                  // derecha, -1 = izquierda); el que SALE se va por el lado
                  // contrario (su animación va en reverse). Con _slideDir 0
                  // no hay desplazamiento: solo fundido.
                  final bool leaving =
                      animation.status == AnimationStatus.reverse;
                  final double dir = leaving ? -_slideDir : _slideDir;
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(dir, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: ClipRRect(
                  key: ValueKey(showing?.id ?? 'placeholder'),
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
                          // Arte compartido mini (46dp) ↔ expandido (~0.88×
                          // ancho): 900px crudos bastan y evita decodificar y
                          // subir a GPU la imagen full-res en cada cambio.
                          cacheWidth: 900,
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
              ),
              // Corazón del doble toque (fuera del ClipRRect: no se recorta
              // aunque el toque sea cerca de un borde del artwork).
              if (_heartBurst > 0)
                Positioned(
                  left: _heartBurstPos.dx - 30,
                  top: _heartBurstPos.dy - 30,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey('burst-$_heartBurst'),
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.favorite_rounded,
                      size: 60,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black38, blurRadius: 10)],
                    ),
                    builder: (context, v, child) {
                      final pop = Curves.elasticOut.transform(
                        (v * 1.25).clamp(0.0, 1.0),
                      );
                      return Opacity(
                        opacity: v > 0.55 ? (1 - v) / 0.45 : 1.0,
                        child: Transform.scale(
                          scale: 0.35 + 0.65 * pop,
                          child: child,
                        ),
                      );
                    },
                  ),
                ),
            ],
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
            // Título/artista a la IZQUIERDA (junto al artwork), no centrados.
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
            // Loader dentro del botón de play mientras la pista carga.
            icon: loading || _buffering
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
            tooltip: _playing ? 'Pausar' : 'Reproducir',
            onPressed: () => _player.togglePlayPause(),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.skip_next_rounded),
            tooltip: 'Siguiente',
            onPressed: _goNext,
          ),
          IconButton(
            color: _isFavorite
                ? Colors.white
                : Colors.white.withValues(alpha: 0.85),
            icon: Icon(
              _isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
            ),
            tooltip: _isFavorite
                ? 'Quitar de favoritos'
                : 'Agregar a favoritos',
            onPressed: _toggleFavorite,
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
    // Separación extra entre el arte heredado y el contenedor de título /
    // controles en el player expandido.
    const double artControlsGap = 24.0;
    final double controlsTop = (artBottomP - 52 - safeTop + artControlsGap)
        .clamp(0.0, double.infinity);

    // Stack a pantalla completa: el CONTENIDO (header + controles) vive en un
    // [SafeArea] propio (nunca bajo los controles del sistema); el sheet de
    // letras va FUERA del SafeArea inferior para que su fondo llegue al borde
    // real de la pantalla (edge-to-edge) y su contenido se ajusta solo con el
    // inset del sistema (ver [_LyricsPeek]).
    return Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              // ── Header: [v] cierre + cola ───────────────────────────
              SizedBox(
                height: 52,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                      IconButton(
                        icon: const Icon(Icons.queue_music_rounded, size: 24),
                        color: Colors.white.withValues(alpha: 0.9),
                        tooltip: 'Cola',
                        onPressed: widget.onOpenQueue,
                      ),
                    ],
                  ),
                ),
              ),
              // ── Contenido: controles debajo del arte heredado ─────
              // IMPORTANTE: el espaciador que baja el bloque hasta quedar
              // justo debajo del arte va FUERA del scrollable (como un hueco
              // simple). Si viviera dentro del SingleChildScrollView, el
              // viewport del scroll taparía TODO el artwork (área vacía) y
              // los gestos del arte (doble toque / deslizar) nunca llegarían.
              SizedBox(height: controlsTop),
              Expanded(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Center(
                    // El bloque usa SIEMPRE el MISMO ancho que el artwork a
                    // escala normal (artSide): solo el arte se encoge al
                    // pausar (0.93). Los controles NO se escalan — se
                    // mantienen alineados con los extremos del arte sin
                    // encogerse al cambiar de canción.
                    child: SizedBox(
                      width: artSide,
                      child: _centerColumn(
                        context,
                        theme: theme,
                        cs: cs,
                        accent: accent,
                        track: track,
                        dur: dur,
                        total: total,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // ── Letras MONTADAS: sheet draggable que se abre arrastrándola.
        //    FUERA del SafeArea inferior: su fondo llega al borde real de la
        //    pantalla (edge-to-edge, por detrás de la barra transparente del
        //    sistema); el contenido respeta el inset dentro del propio sheet.
        //    Va en un [Positioned.fill] (no en un [Positioned] sin altura)
        //    para que el LayoutBuilder interno reciba una altura ACOTADA:
        //    con altura infinita el cálculo del sheet da NaN y no se pinta.
        Positioned.fill(
          child: _LyricsPeek(
            track: track,
            accent: accent,
            open: _lyricsOpen,
            onChanged: (v) => _setLyricsOpen(v),
          ),
        ),
      ],
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
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // [playlist] Titulo/artista [favorito]: los botones flanquean el
        // título centrado (como pidió el usuario). Los botones extremos se
        // desplazan hacia afuera para que su GLIFO quede alineado con el
        // extremo del artwork (el IconButton centra el icono en su área
        // táctil de 48dp; [_flushGlyph] compensa esa holgura).
        Row(
          children: [
            IconButton(
              icon: _flushGlyph(
                right: false,
                icon: const Icon(Icons.playlist_add_rounded),
              ),
              color: Colors.white,
              tooltip: 'Agregar a playlist',
              onPressed: track == null
                  ? null
                  : () => showAddToPlaylistDialog(context, track),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
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
                  if (track != null && track.artist.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: _flushGlyph(
                right: true,
                icon: Icon(
                  _isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                ),
              ),
              color: _isFavorite
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.85),
              tooltip: _isFavorite
                  ? 'Quitar de favoritos'
                  : 'Agregar a favoritos',
              onPressed: _toggleFavorite,
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Barra de progreso (limpia, sin dot) a TODO el ancho del bloque
        // (= ancho del artwork): sus extremos coinciden con los del arte.
        // Los números de duración van DEBAJO, en los extremos de la barra.
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              // Barra LIMPIA, como en desktop: línea fina sin dot ni
              // indicador; se arrastra/toca la propia línea.
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                showValueIndicator: ShowValueIndicator.never,
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
            // Separación del tiempo respecto a la barra: no queda pegado.
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fmt(
                      _dragging
                          ? Duration(milliseconds: _dragValue.round())
                          : _pos,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _fmt(dur),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Transporte: spaceBetween para que el primero y el último botón
        // queden en los EXTREMOS del bloque. Los extremos (shuffle/repeat)
        // se desplazan hacia afuera con [_flushGlyph] para que su glifo
        // quede alineado con el extremo del artwork (igual que la barra).
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Transform.translate(
              // Desplaza todo el botón hacia afuera para que su glifo quede
              // alineado con el extremo izquierdo del artwork.
              offset: const Offset(-11, 0),
              child: _ModeButton(
                icon: Icons.shuffle_rounded,
                active: _player.shuffle.value,
                accent: accent,
                onPressed: _player.toggleShuffle,
              ),
            ),
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              size: 40,
              onPressed: track == null ? null : _goPrev,
            ),
            _PlayPauseButton(
              playing: _playing,
              accent: accent,
              // Mientras la pista se carga, el loader va DENTRO del botón
              // de play (reemplaza el icono), no como spinner suelto.
              loading: _buffering || _preparingActive,
              onPressed: track == null ? null : _player.togglePlayPause,
            ),
            _ControlButton(
              icon: Icons.skip_next_rounded,
              size: 40,
              onPressed: track == null ? null : _goNext,
            ),
            Transform.translate(
              offset: const Offset(11, 0),
              child: _ModeButton(
                icon: _repeatIcon(_player.repeatMode.value),
                active: _player.repeatMode.value != LoopMode.off,
                accent: accent,
                onPressed: _player.toggleRepeat,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// Compensa la holgura interna del [IconButton] (el glifo queda centrado
  /// en el área táctil de 48dp): lo desplaza hacia el borde de la fila para
  /// que quede alineado con el extremo del artwork (y de la barra de
  /// progreso), sin mover el área táctil.
  Widget _flushGlyph({
    required Widget icon,
    required bool right,
    double iconSize = 24,
  }) {
    final shift = (48 - iconSize) / 2;
    return Transform.translate(
      offset: Offset(right ? shift : -shift, 0),
      child: icon,
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
    this.size = 38,
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
  final bool loading;
  final VoidCallback? onPressed;

  const _PlayPauseButton({
    required this.playing,
    required this.accent,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Círculo de TAMAÑO FIJO en ambos estados: con el loader el botón no
      // se encoge (antes el círculo derivaba del tamaño del hijo y el loader
      // de 24px lo achicaba).
      width: 64,
      height: 64,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: loading
                ? SizedBox(
                    // Loader casi del tamaño óptico del icono de play (46),
                    // no un puntito: reemplaza al icono dentro del mismo
                    // botón mientras la pista se carga.
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      color: accent,
                    ),
                  )
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 46,
                    color: accent,
                  ),
          ),
        ),
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
      iconSize: 26,
      color: active ? Colors.white : Colors.white.withValues(alpha: 0.6),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

/// Fondo plano de acento con crossfade RGB al cambiar de pista.
///
/// Anima SOLO un [ColoredBox] (capa barata, sin saveLayer): el contenido va
/// como `child` y no se reconstruye en cada frame. A propósito NO se
/// interpola en HSL (el camino por el círculo de matiz generaba un tercer
/// color vívido intermedio).
class _AccentBackground extends StatefulWidget {
  final Color color;
  final Widget child;

  const _AccentBackground({required this.color, required this.child});

  @override
  State<_AccentBackground> createState() => _AccentBackgroundState();
}

class _AccentBackgroundState extends State<_AccentBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  late Color _from;
  late Color _to;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // Misma curva que el sheet de letras y el miniplayer: los tres fundidos
    // corren en fase (misma duración y curva, arrancan en el mismo frame).
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _from = widget.color;
    _to = widget.color;
  }

  @override
  void didUpdateWidget(covariant _AccentBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color != oldWidget.color) {
      // Si estaba animando, parte del color REAL mostrado (no del objetivo
      // anterior) hacia el nuevo acento.
      final current =
          _ctrl.isAnimating ? Color.lerp(_from, _to, _anim.value)! : _to;
      appLog('UI', 'bg-anim ${colorHex(current)} → ${colorHex(widget.color)}');
      _from = current;
      _to = widget.color;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final color = (_ctrl.isAnimating || _ctrl.value > 0)
            ? Color.lerp(_from, _to, _anim.value)!
            : _to;
        return ColoredBox(color: color, child: child);
      },
      child: widget.child,
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

  /// Comportamiento: el sheet SIGUE al dedo 1:1 (recorre exactamente lo que
  /// recorre el dedo, nunca más rápido). Al soltar, un recorrido CORTO hacia
  /// arriba lo abre COMPLETO (y uno corto hacia abajo lo cierra del todo):
  /// el umbral es por DISTANCIA recorrida, no por sensibilidad.
  // Recorrido mínimo (fracción de la altura de referencia) para abrir/cerrar
  // COMPLETO al soltar: ~4.5% de la pantalla (~40dp efectivos tras el slop
  // del touch) en vez de ~35-40%.
  static const double _snapTravelFrac = 0.045;

  double _dragDist = 0;
  double _dragStartOpen = 0;
  double _refH = 1;

  /// Color previo del sheet para el fundido (igual que el fondo del player).
  Color? _sheetPrev;

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
    _dragDist = 0;
    _dragStartOpen = _open;
  }

  /// [travel] = recorrido total del sheet (recogido → abierto): el sheet se
  /// mueve 1:1 con el dedo sobre ese recorrido.
  void _onDragUpdate(DragUpdateDetails d, double refH, double travel) {
    _refH = refH;
    _dragDist += d.delta.dy;
    setState(() {
      _open = (_dragStartOpen - _dragDist / travel).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    final double vel = d.primaryVelocity ?? 0.0;
    final double snapTravel = _refH * _snapTravelFrac;
    final bool target;
    if (vel.abs() > 400) {
      // Flick rápido: abre al arrastrar arriba y cierra al arrastrar abajo,
      // sin depender de la distancia recorrida.
      target = vel < 0;
    } else if (_dragDist <= -snapTravel) {
      // Recorrido corto hacia arriba -> se abre COMPLETO.
      target = true;
    } else if (_dragDist >= snapTravel) {
      // Recorrido corto hacia abajo -> se cierra del todo.
      target = false;
    } else {
      // Movimiento mínimo: mantén el estado actual.
      target = _open >= 0.5;
    }
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
    // (El color del sheet lo calcula el tween del `LayoutBuilder`: fondo
    // plano = acento oscurecido para contrastar con el player.)
    return Align(
      alignment: Alignment.bottomCenter,
      child: LayoutBuilder(
        builder: (context, c) {
          // Altura de referencia: si el padre no acota la altura (p. ej. un
          // [Positioned] sin top/height), usa la pantalla para que el cálculo
          // del sheet sea finito (con ∞ el resultado es NaN y no se pinta).
          final double maxH = c.maxHeight.isFinite
              ? c.maxHeight
              : MediaQuery.sizeOf(context).height;
          // Inset inferior del sistema (gestos ~24dp, 3 botones ~48-60dp): el
          // sheet se apoya en el borde real de la pantalla (su fondo llega
          // abajo del todo), pero su CONTENIDO (handle + letras) respeta el
          // inset y nunca queda bajo los botones de navegación. Por eso el
          // alto colapsado incluye el inset: handle de 48dp arriba + banda de
          // fondo del sheet por debajo hasta el borde.
          final double bottomInset = MediaQuery.paddingOf(context).bottom;
          final collapsed = 48.0 + bottomInset;
          final openH = maxH * 0.80;
          // Recorrido total del sheet (recogido → abierto): se usa para que
          // el sheet siga al dedo 1:1 durante el arrastre.
          final double travel = openH - collapsed;
          final sheetH = collapsed + (_open * travel);

          // El COLOR del sheet se anima con el mismo tween que el fondo del
          // player (350ms, easeOutCubic): antes cambiaba al instante y se
          // adelantaba al fondo. El AnimatedContainer interior conserva SOLO
          // la animación de altura; el color lo pinta el tween exterior para
          // no encadenar dos animaciones implícitas.
          final Color target =
              Color.lerp(widget.accent, Colors.black, 0.35)!;
          final Color begin = _sheetPrev ?? target;
          if (_sheetPrev != target) {
            appLog('UI', 'sheet ${colorHex(_sheetPrev)} → ${colorHex(target)}');
            _sheetPrev = target;
          }
          return TweenAnimationBuilder<Color?>(
            key: ValueKey(target),
            tween: ColorTween(begin: begin, end: target),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            // El subárbol estático va en `child` (se construye UNA vez): por
            // frame del fundido solo se reconstruye el DecoratedBox del
            // color. Antes el builder reconstruía handle + letras en cada
            // frame (tween a 90Hz = caída de fps en el cambio).
            builder: (context, color, child) {
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: child,
              );
            },
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: sheetH,
              width: double.infinity,
              // El padding del inset va AQUÍ (dentro de la caja con color de
              // arriba) para que el fondo llegue al borde real de la pantalla
              // (edge-to-edge, bajo la barra de navegación) y solo el
              // contenido (handle + letras) respete el inset.
              padding: EdgeInsets.only(bottom: bottomInset),
              decoration: const BoxDecoration(color: Colors.transparent),
              child: Container(
                decoration: const BoxDecoration(),
                child: Column(
                    children: [
                // Handle (siempre visible, ~48px). El arrastre está acotado
                // al handle para no chocar con el scroll de las letras.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: (d) => _onDragUpdate(d, maxH, travel),
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
                const Expanded(child: LyricsView(embedded: true)),
              ],
            ),
          ),
        ),
    );
        },
      ),
    );
  }
}
