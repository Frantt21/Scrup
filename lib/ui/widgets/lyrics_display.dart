import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/synced_lyrics.dart';
import '../../l10n/generated/app_localizations.dart';

const String kGapMarker = '•••';

class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueNotifier<Duration> positionNotifier;
  final ValueListenable<Duration>? durationNotifier;
  final String? audioPath;
  final Duration lyricsOffset;
  final void Function(Duration)? onTap;
  final Color? accentColor;
  final bool? sweepEnabled;

  const LyricsDisplay({
    super.key,
    required this.lyrics,
    required this.positionNotifier,
    this.durationNotifier,
    this.audioPath,
    this.lyricsOffset = Duration.zero,
    this.onTap,
    this.accentColor,
    this.sweepEnabled,
  });

  @override
  State<LyricsDisplay> createState() => _LyricsDisplayState();
}

class _LyricsDisplayState extends State<LyricsDisplay>
    with AutomaticKeepAliveClientMixin {
  late ScrollController _controller;
  final Map<int, GlobalKey> _itemKeys = {};
  bool _showSyncButton = false;
  int _lastAutoScrolledIndex = -1;
  bool _userHasScrolled = false;
  List<LyricLine> _processedLines = [];
  SyncedLyrics? _lastLyrics;
  bool _isSweepEnabled = false;

  /// Índice ACTIVO en el listado VISUAL (incluye los gaps '•••'). Se deriva
  /// de la posición y no del índice original del reproductor: las líneas de
  /// gap no existen en SyncedLyrics, así que el índice original nunca las
  /// señala y los puntos quedaban apagados durante intros/instrumentales.
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);

  @override
  bool get wantKeepAlive => true;

  List<LyricLine> get _lines {
    if (_lastLyrics != widget.lyrics) {
      _lastLyrics = widget.lyrics;
      _processedLines = _computeLinesWithGaps(widget.lyrics.lines);
    }
    return _processedLines;
  }

  Duration get _totalDuration =>
      widget.durationNotifier?.value ?? const Duration(seconds: 5);

  Duration _lineEnd(int i) =>
      i < _lines.length - 1 ? _lines[i + 1].timestamp : _totalDuration;

  List<LyricLine> _computeLinesWithGaps(List<LyricLine> original) {
    if (original.isEmpty) return [];
    final result = <LyricLine>[];
    if (original.first.timestamp.inSeconds > 10) {
      result.add(LyricLine(timestamp: Duration.zero, text: kGapMarker));
    }
    for (var i = 0; i < original.length; i++) {
      result.add(original[i]);
      if (i < original.length - 1) {
        final next = original[i + 1];
        final chars = original[i].text.length;
        var est = ((chars / 12.0) * 1000).toInt() + 1500;
        final dur = (next.timestamp - original[i].timestamp).inMilliseconds;
        if (est > dur - 1000) est = dur - 1000;
        final approx = original[i].timestamp + Duration(milliseconds: est);
        if (next.timestamp - approx > const Duration(seconds: 8)) {
          result.add(LyricLine(timestamp: approx, text: kGapMarker));
        }
      }
    }
    return result;
  }

  /// Índice activo en el LISTADO VISUAL (gaps incluidos), replicando la
  /// semántica de SyncedLyrics.getCurrentLineIndex: exacto para líneas
  /// karaoke (el adelanto cortaría el último barrido) y con adelanto de
  /// [kCurrentLineAdvance] para las demás — los gaps, sin palabras, usan el
  /// adelanto como cualquier línea sincronizada por línea.
  int _computeActiveDisplayIndex(Duration position) {
    final posMs = (position - widget.lyricsOffset).inMilliseconds;
    var exact = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timestamp.inMilliseconds <= posMs) {
        exact = i;
      } else {
        break;
      }
    }
    if (exact >= 0 && _lines[exact].hasWords) return exact;

    final adjustedPosMs = posMs + kCurrentLineAdvance.inMilliseconds;
    for (var i = _lines.length - 1; i >= 0; i--) {
      if (_lines[i].timestamp.inMilliseconds <= adjustedPosMs) return i;
    }
    return -1;
  }

  void _onPositionChanged() {
    final di = _computeActiveDisplayIndex(widget.positionNotifier.value);
    if (di == _activeIndex.value) return;
    _activeIndex.value = di;
    _onActiveIndexChanged(di);
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkButtonVisibility);
    widget.positionNotifier.addListener(_onPositionChanged);
    _onPositionChanged();
    _loadSweepSetting();
    for (var i = 0; i < _lines.length; i++) _itemKeys[i] = GlobalKey();
  }

  Future<void> _loadSweepSetting() async {
    if (widget.sweepEnabled != null) {
      if (mounted && widget.sweepEnabled != _isSweepEnabled) {
        setState(() => _isSweepEnabled = widget.sweepEnabled!);
      }
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('lyrics_sweep_enabled') ?? false;
      if (mounted && enabled != _isSweepEnabled) {
        setState(() => _isSweepEnabled = enabled);
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(LyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sweepEnabled != widget.sweepEnabled) _loadSweepSetting();
    if (oldWidget.lyrics != widget.lyrics ||
        oldWidget.audioPath != widget.audioPath) {
      _itemKeys.clear();
      for (var i = 0; i < _lines.length; i++) _itemKeys[i] = GlobalKey();
      _showSyncButton = false;
      _lastAutoScrolledIndex = -1;
      _userHasScrolled = false;
      _loadSweepSetting();
      _onPositionChanged();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpTo(0);
      });
    } else if (oldWidget.lyricsOffset != widget.lyricsOffset) {
      // Ajuste en caliente desde el diálogo de sincronización: recalcular el
      // índice activo AL INSTANTE (sin esperar al próximo tick de posición,
      // que con la canción pausada podría no llegar nunca).
      _onPositionChanged();
    }
  }

  @override
  void dispose() {
    widget.positionNotifier.removeListener(_onPositionChanged);
    _controller.removeListener(_checkButtonVisibility);
    _controller.dispose();
    super.dispose();
  }

  void _checkButtonVisibility() {
    final di = _activeIndex.value;
    if (di < 0 || !_controller.hasClients) {
      if (_showSyncButton) setState(() => _showSyncButton = false);
      return;
    }
    final key = _itemKeys[di];
    if (key?.currentContext == null) {
      if (!_showSyncButton) setState(() => _showSyncButton = true);
      return;
    }
    final ro = key!.currentContext!.findRenderObject();
    if (ro == null) return;
    final vp = RenderAbstractViewport.of(ro);
    final t = vp.getOffsetToReveal(ro, 0.5).offset;
    final isFar =
        (_controller.offset - t).abs() > _controller.position.viewportDimension / 3;
    if (_showSyncButton != isFar) setState(() => _showSyncButton = isFar);
  }

  void _syncToCurrentLine() {
    final di = _activeIndex.value;
    if (di < 0 || !_controller.hasClients) return;
    final key = _itemKeys[di];
    void scroll() {
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(key!.currentContext!,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
            alignment: 0.5);
      }
    }

    if (key?.currentContext == null) {
      _controller.jumpTo(
          (di * 70.0).clamp(0.0, _controller.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) => scroll());
    } else {
      scroll();
    }
    _lastAutoScrolledIndex = di;
    _userHasScrolled = false;
    setState(() => _showSyncButton = false);
  }

  /// Seguimiento de scroll al cambiar la línea activa (líneas reales Y gaps:
  /// durante una intro/instrumental la vista sigue a los puntos).
  void _onActiveIndexChanged(int di) {
    if (di < 0 || !_controller.hasClients) return;
    if (_userHasScrolled) {
      _checkButtonVisibility();
      return;
    }
    if (di != _lastAutoScrolledIndex) {
      _lastAutoScrolledIndex = di;
      final key = _itemKeys[di];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(key!.currentContext!,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
            alignment: 0.5);
      } else {
        final est =
            (di * 70.0).clamp(0.0, _controller.position.maxScrollExtent);
        if ((_controller.offset - est).abs() > 500) {
          _controller.jumpTo(est);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (key?.currentContext != null) {
              Scrollable.ensureVisible(key!.currentContext!,
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOutCubic,
                  alignment: 0.5);
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    return Stack(
      children: [
        ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent
                  ],
                  stops: [0.0, 0.1, 0.9, 1.0])
              .createShader(rect),
          blendMode: BlendMode.dstIn,
          child: NotificationListener<UserScrollNotification>(
            onNotification: (n) {
              if (n.direction != ScrollDirection.idle) _userHasScrolled = true;
              return false;
            },
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(vertical: 200),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                return ValueListenableBuilder<int>(
                  valueListenable: _activeIndex,
                  builder: (context, activeIndex, _) {
                    final isCurrent = index == activeIndex;
                    final line = _lines[index];
                    final isGap = line.text == kGapMarker;
                    // Fin de la línea para el sweep:
                    //  · Gap activo → la siguiente línea del listado es el
                    //    fin del silencio (ventana de los puntos).
                    //  · Línea real activa → saltar los '•••' intercalados
                    //    (su timestamp estimado recortaría el barrido) y usar
                    //    la siguiente línea REAL.
                    //  · Resto → la siguiente del listado (solo cosmético).
                    final Duration endTime;
                    if (isGap || !isCurrent) {
                      endTime = index < _lines.length - 1
                          ? _lines[index + 1].timestamp
                          : _totalDuration;
                    } else {
                      var j = index + 1;
                      while (j < _lines.length &&
                          _lines[j].text == kGapMarker) {
                        j++;
                      }
                      endTime = j < _lines.length
                          ? _lines[j].timestamp
                          : _totalDuration;
                    }
                    return GestureDetector(
                      onTap: widget.onTap != null
                          ? () => widget.onTap!(line.timestamp)
                          : null,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        key: _itemKeys[index],
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                        child: _KaraokeLine(
                          line: line,
                          isCurrent: isCurrent,
                          isGap: isGap,
                          startTime: line.timestamp,
                          endTime: endTime,
                          positionNotifier: widget.positionNotifier,
                          offset: widget.lyricsOffset,
                          accentColor: widget.accentColor,
                          isSweepEnabled: _isSweepEnabled,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
        if (_showSyncButton)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _syncToCurrentLine,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 1),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.sync_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.syncLyrics,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── _KaraokeLine ─────────────────────────────────────────────────────

class _KaraokeLine extends StatelessWidget {
  final LyricLine line;
  final bool isCurrent;
  final bool isGap;
  final Duration startTime;
  final Duration endTime;
  final ValueNotifier<Duration> positionNotifier;
  final Duration offset;
  final Color? accentColor;
  final bool isSweepEnabled;

  const _KaraokeLine({
    required this.line,
    required this.isCurrent,
    this.isGap = false,
    required this.startTime,
    required this.endTime,
    required this.positionNotifier,
    required this.offset,
    this.accentColor,
    this.isSweepEnabled = true,
  });

  Color get _activeColor =>
      accentColor == null ? Colors.white : _readableAccent(accentColor!);
  Color get _inactiveColor => accentColor == null
      ? Colors.white.withValues(alpha: 0.3)
      : _readableAccent(accentColor!).withValues(alpha: 0.3);

  static Color _readableAccent(Color c) =>
      c.computeLuminance() < 0.35 ? Color.lerp(c, Colors.white, 0.5)! : c;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.bold,
        height: 1.3,
        fontFamily: 'Roboto');

    final tokens = computeTokens();
    final shouldAnimate = isCurrent && isSweepEnabled && tokens.karaoke;

    return AnimatedScale(
      scale: isCurrent ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutQuad,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: double.infinity,
        child: isGap
            ? _buildDots(baseStyle)
            : shouldAnimate
                ? _buildSweep(baseStyle, tokens.list)
                : _buildStatic(baseStyle, tokens.list,
                    isCurrent ? _activeColor : _inactiveColor),
      ),
    );
  }

  /// Los tres puntos de silencio ('•••'). Inactivos: tenues. Activos:
  /// encendidos en fijo, o en BARRIDO secuencial si el karaoke está activo —
  /// cada punto cubre un tercio del hueco y se llena con el mismo gradiente
  /// del sweep de palabras, como indicador de cuánto queda de intro o
  /// instrumental.
  Widget _buildDots(TextStyle baseStyle) {
    const dots = ['•', '•', '•'];
    final startMs = startTime.inMilliseconds;
    final endMs = max(startMs + 1, endTime.inMilliseconds);
    final window = max(1, (endMs - startMs) ~/ dots.length);

    return ValueListenableBuilder<Duration>(
      valueListenable: positionNotifier,
      builder: (context, position, _) {
        final currentMs = (position - offset).inMilliseconds;
        final children = <Widget>[];
        for (var i = 0; i < dots.length; i++) {
          final dot = dots[i];
          if (!isCurrent) {
            children.add(
                Text(dot, style: baseStyle.copyWith(color: _inactiveColor)));
            continue;
          }
          if (!isSweepEnabled) {
            children.add(
                Text(dot, style: baseStyle.copyWith(color: _activeColor)));
            continue;
          }
          final wStart = startMs + i * window;
          final wEnd = min(endMs, wStart + window);
          double progress;
          if (currentMs >= wEnd) {
            progress = 1.0;
          } else if (currentMs <= wStart) {
            progress = 0.0;
          } else {
            progress = (currentMs - wStart) / max(1, wEnd - wStart);
          }
          children.add(_KaraokeWord(
            word: dot,
            progress: progress.clamp(0.0, 1.0),
            style: baseStyle,
            activeColor: _activeColor,
            inactiveColor: _inactiveColor,
          ));
        }
        return Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6.0,
          runSpacing: 4.0,
          children: children,
        );
      },
    );
  }

  /// Tokens visuales de la línea, calculados por `build` y compartidos por
  /// ambos modos de render. Tanto el estático como el sweep consumen esta
  /// MISMA lista, así el layout es idéntico al ganar/perder el foco y las
  /// palabras no "saltan".
  ///
  /// Cada palabra del proveedor se trocea por sus espacios internos: los
  /// datos word-by-word (LRCLIB/KPoe, TTML, SyncLRC) traen espacios dobles
  /// o tabs dentro del texto de una palabra que el texto plano normalizado
  /// no tiene, y eran los responsables de la separación visible solo en la
  /// línea activa.
  _LineTokens computeTokens() {
    final words = line.words;
    if (words != null && words.isNotEmpty) {
      final lineEndMs = endTime.inMilliseconds;
      final toks = <_LineToken>[];
      for (var i = 0; i < words.length; i++) {
        final wStartMs = words[i].timestamp.inMilliseconds;
        // End of this word = start of next word, or line end for last word
        var wEndMs = i < words.length - 1
            ? words[i + 1].timestamp.inMilliseconds
            : max(wStartMs + 1, lineEndMs);
        wEndMs = max(wStartMs + 1, wEndMs);
        for (final piece in words[i].text.trim().split(RegExp(r'\s+'))) {
          if (piece.isEmpty) continue;
          toks.add(_LineToken(piece, wStartMs, wEndMs));
        }
      }
      if (toks.isNotEmpty) return _LineTokens(toks, true);
    }
    // Sin palabras (o todas vacías): tokens desde el texto plano, ya
    // normalizado; las ventanas quedan en cero porque no hay sweep.
    return _LineTokens(
      [
        for (final t in line.text.split(' '))
          if (t.isNotEmpty) _LineToken(t, 0, 0),
      ],
      false,
    );
  }

  /// Smooth sweep: computes progress for each token from REAL timestamps,
  /// no TweenAnimationBuilder. The audio position drives everything.
  ///
  /// El fin de la última palabra es el timestamp de la línea siguiente SIN
  /// adelanto: para líneas karaoke el índice cambia de línea de forma
  /// exacta (ver getCurrentLineIndex), así que la palabra tiene su ventana
  /// completa y siempre llega a pintarse.
  Widget _buildSweep(TextStyle baseStyle, List<_LineToken> tokens) {
    return ValueListenableBuilder<Duration>(
      valueListenable: positionNotifier,
      builder: (context, position, _) {
        final currentMs = (position - offset).inMilliseconds;

        final List<Widget> wordWidgets = [];
        for (var i = 0; i < tokens.length; i++) {
          // Mismo espaciado que las líneas estáticas: token + espacio.
          // Sin él, la línea activa se ve apretada frente a las demás.
          final label = tokens[i].text + (i < tokens.length - 1 ? ' ' : '');
          final wStartMs = tokens[i].startMs;
          final wEndMs = tokens[i].endMs;
          final wordDuration = max(1, wEndMs - wStartMs);

          // Progress through this specific token using real timestamps
          double wordProgress;
          if (currentMs >= wEndMs) {
            wordProgress = 1.0;
          } else if (currentMs <= wStartMs) {
            wordProgress = 0.0;
          } else {
            wordProgress = (currentMs - wStartMs) / wordDuration;
          }

          wordWidgets.add(
            _KaraokeWord(
              word: label,
              progress: wordProgress.clamp(0.0, 1.0),
              style: baseStyle,
              activeColor: _activeColor,
              inactiveColor: _inactiveColor,
            ),
          );
        }

        return Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          // El hueco entre palabras es SOLO el espacio dentro del Text:
          // un espaciado extra aquí las hacía verse separadas.
          spacing: 0.0,
          runSpacing: 4.0,
          children: wordWidgets,
        );
      },
    );
  }

  Widget _buildStatic(
      TextStyle baseStyle, List<_LineToken> tokens, Color color) {
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      // Mismo criterio que el sweep: solo el espacio tipográfico.
      spacing: 0.0,
      runSpacing: 4.0,
      children: [
        for (int i = 0; i < tokens.length; i++)
          Text(tokens[i].text + (i < tokens.length - 1 ? ' ' : ''),
              style: baseStyle.copyWith(color: color))
      ],
    );
  }
}

/// Tokens de una línea karaoke + si vienen de datos word-by-word reales
/// (`karaoke`) o del texto plano (sin ventanas de tiempo).
class _LineTokens {
  final List<_LineToken> list;
  final bool karaoke;
  const _LineTokens(this.list, this.karaoke);
}

/// Trozo visual de una línea karaoke: una pieza SIN espacios con su ventana
/// de tiempo (startMs/endMs solo relevantes para el sweep).
class _LineToken {
  final String text;
  final int startMs;
  final int endMs;
  const _LineToken(this.text, this.startMs, this.endMs);
}

// ─── _KaraokeWord ─────────────────────────────────────────────────────

class _KaraokeWord extends StatelessWidget {
  final String word;
  final double progress;
  final TextStyle style;
  final Color activeColor;
  final Color inactiveColor;

  const _KaraokeWord({
    required this.word,
    required this.progress,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    if (progress >= 1.0) {
      return Text(word, style: style.copyWith(color: activeColor));
    }
    if (progress <= 0.0) {
      return Text(word, style: style.copyWith(color: inactiveColor));
    }

    // Smooth sweep gradient: narrow active band sweeps left→right
    // Edge is ~15% of word width for a soft but focused transition
    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          colors: [
            activeColor,
            activeColor,
            activeColor.withValues(alpha: 0.6),
            inactiveColor,
          ],
          stops: [
            0.0,
            max(0.0, progress - 0.15),
            progress.clamp(0.0, 1.0),
            min(1.0, progress + 0.15),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          tileMode: TileMode.clamp,
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: Text(word, style: style.copyWith(color: Colors.white)),
    );
  }
}
