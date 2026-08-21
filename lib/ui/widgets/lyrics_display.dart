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
  final ValueNotifier<int?> currentIndexNotifier;
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
    required this.currentIndexNotifier,
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

  int _mapToDisplayIndex(int? oi) {
    if (oi == null || oi < 0 || widget.lyrics.lines.isEmpty) return -1;
    final target = widget.lyrics.lines[oi].timestamp;
    var shift = 0;
    for (final l in _lines) {
      if (l.text == kGapMarker && l.timestamp <= target) shift++;
    }
    return oi + shift;
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkButtonVisibility);
    widget.currentIndexNotifier.addListener(_onIndexChanged);
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    widget.currentIndexNotifier.removeListener(_onIndexChanged);
    _controller.removeListener(_checkButtonVisibility);
    _controller.dispose();
    super.dispose();
  }

  void _checkButtonVisibility() {
    final di = _mapToDisplayIndex(widget.currentIndexNotifier.value);
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
    final di = _mapToDisplayIndex(widget.currentIndexNotifier.value);
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

  void _onIndexChanged() {
    final di = _mapToDisplayIndex(widget.currentIndexNotifier.value);
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
                return ValueListenableBuilder<int?>(
                  valueListenable: widget.currentIndexNotifier,
                  builder: (context, currentIndex, _) {
                    final di = _mapToDisplayIndex(currentIndex);
                    final isCurrent = index == di;
                    final line = _lines[index];
                    // Fin de ESTA línea (la siguiente en la lista; para la
                    // última, la duración total del medio).
                    final endTime =
                        index < _lines.length - 1 ? _lines[index + 1].timestamp : _totalDuration;
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
                      const Icon(Icons.sync, color: Colors.white, size: 20),
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
  final Duration startTime;
  final Duration endTime;
  final ValueNotifier<Duration> positionNotifier;
  final Duration offset;
  final Color? accentColor;
  final bool isSweepEnabled;

  const _KaraokeLine({
    required this.line,
    required this.isCurrent,
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

    final hasRealWords = line.words != null && line.words!.isNotEmpty;
    final shouldAnimate = isCurrent && isSweepEnabled && hasRealWords;

    return AnimatedScale(
      scale: isCurrent ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutQuad,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: double.infinity,
        child: shouldAnimate
            ? _buildSweep(baseStyle)
            : _buildStatic(baseStyle, isCurrent ? _activeColor : _inactiveColor),
      ),
    );
  }

  /// Smooth sweep: computes progress for each word from REAL timestamps,
  /// no TweenAnimationBuilder. The audio position drives everything.
  Widget _buildSweep(TextStyle baseStyle) {
    final words = line.words!;
    // La línea pierde el estado "actual" en nextTs - kCurrentLineAdvance
    // (adelanto del índice), así que la última palabra debe completar su
    // sweep justo ahí; si no, nunca llega a pintarse entera.
    final lineEndMs =
        endTime.inMilliseconds - kCurrentLineAdvance.inMilliseconds;

    return ValueListenableBuilder<Duration>(
      valueListenable: positionNotifier,
      builder: (context, position, _) {
        final currentMs = (position - offset).inMilliseconds;

        final List<Widget> wordWidgets = [];
        for (var i = 0; i < words.length; i++) {
          final wStartMs = words[i].timestamp.inMilliseconds;
          // End of this word = start of next word, or line end for last word
          final wEndMs = i < words.length - 1
              ? words[i + 1].timestamp.inMilliseconds
              : max(wStartMs + 1, lineEndMs);
          final wordDuration = max(1, wEndMs - wStartMs);

          // Progress through this specific word using real timestamps
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
              word: words[i].text,
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
          spacing: 2.0,
          runSpacing: 4.0,
          children: wordWidgets,
        );
      },
    );
  }

  Widget _buildStatic(TextStyle baseStyle, Color color) {
    final words = line.text.split(' ');
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2.0,
      runSpacing: 4.0,
      children: [
        for (int i = 0; i < words.length; i++)
          Text(words[i] + (i < words.length - 1 ? ' ' : ''),
              style: baseStyle.copyWith(color: color))
      ],
    );
  }
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
