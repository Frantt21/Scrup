import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/binaries.dart';
import '../../core/synced_lyrics.dart';
import '../../l10n/generated/app_localizations.dart';

/// Línea fantasma para gaps instrumentales (forawn_mobile).
const String kGapMarker = '•••';

/// Vista de letras sincronizadas con auto-scroll, resaltado de la línea
/// actual, modo karaoke (sweep palabra por palabra con energía real del
/// audio vía ffmpeg) y líneas fantasma para los gaps instrumentales.
///
/// Port del `LyricsDisplay` de forawn (que a su vez porta forawn_mobile):
/// - auto-scroll + botón de sincronizar cuando el usuario se aleja,
/// - tap en una línea para hacer seek,
/// - blur de las líneas inactivas,
/// - gaps '•••' y sweep con waveform (ffmpeg, ya que `audio_waveforms` solo
///   soporta Android/iOS).
class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;

  /// Índice de la línea actual (calculado por el padre sobre las líneas
  /// ORIGINALES; este widget lo mapea a la lista con gaps).
  final ValueNotifier<int?> currentIndexNotifier;

  /// Posición de reproducción (tick a tick).
  final ValueNotifier<Duration> positionNotifier;

  /// Duración total de la canción (para el progreso por waveform).
  final ValueListenable<Duration>? durationNotifier;

  /// Archivo de audio para extraer la energía (waveform) con ffmpeg.
  final String? audioPath;

  /// Desfase de sincronización (se resta a la posición para el sweep).
  final Duration lyricsOffset;

  /// Tap en una línea → seek a ese timestamp.
  final void Function(Duration)? onTap;

  /// Color del artwork de la canción: las letras se tintan con él (la línea
  /// activa se aclara hacia blanco para el foco). `null` = blanco clásico.
  final Color? accentColor;

  /// Modo karaoke (sweep palabra por palabra). Si se pasa, tiene prioridad
  /// sobre la preferencia guardada (el toggle de la cabecera de la vista);
  /// si es `null`, se lee la clave `lyrics_sweep_enabled` de las prefs.
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

  // Líneas procesadas con gaps instrumentales ('•••').
  List<LyricLine> _processedLines = [];
  SyncedLyrics? _lastLyrics;

  // Modo karaoke (sweep palabra por palabra).
  bool _isSweepEnabled = false;

  // Waveform: energía real del audio extraída con ffmpeg (equivalente al
  // audio_waveforms de forawn_mobile, que no soporta Linux/Windows).
  List<double> _waveformData = [];
  int _waveformGen = 0;

  @override
  bool get wantKeepAlive => true;

  List<LyricLine> get _lines {
    if (_lastLyrics != widget.lyrics) {
      _lastLyrics = widget.lyrics;
      _processedLines = _computeLinesWithGaps(widget.lyrics.lines);
    }
    return _processedLines;
  }

  /// Inserta líneas fantasma '•••' en los gaps instrumentales largos
  /// (misma función que forawn_mobile).
  List<LyricLine> _computeLinesWithGaps(List<LyricLine> original) {
    if (original.isEmpty) return [];

    final result = <LyricLine>[];
    // Espacio instrumental muy largo al inicio de la canción
    if (original.first.timestamp.inSeconds > 10) {
      result.add(LyricLine(timestamp: Duration.zero, text: kGapMarker));
    }

    for (var i = 0; i < original.length; i++) {
      final current = original[i];
      result.add(current);

      if (i < original.length - 1) {
        final next = original[i + 1];

        // Tiempo aproximado de canto de esta línea
        final chars = current.text.length;
        var estimatedMs = ((chars / 12.0) * 1000).toInt() + 1500;

        final durationUntilNext =
            (next.timestamp - current.timestamp).inMilliseconds;

        // Limitar la estimación a no invadir el tiempo de la próxima línea
        if (estimatedMs > durationUntilNext - 1000) {
          estimatedMs = durationUntilNext - 1000;
        }

        final currentEndApprox =
            current.timestamp + Duration(milliseconds: estimatedMs);

        // Si quedan más de 8 segundos hasta la siguiente vocal
        if (next.timestamp - currentEndApprox > const Duration(seconds: 8)) {
          result.add(LyricLine(timestamp: currentEndApprox, text: kGapMarker));
        }
      }
    }
    return result;
  }

  /// Convierte el índice de línea original (sin gaps) al índice en la
  /// lista procesada (con líneas '•••' insertadas).
  int _mapToDisplayIndex(int? originalIndex) {
    if (originalIndex == null ||
        originalIndex < 0 ||
        widget.lyrics.lines.isEmpty) {
      return -1;
    }
    final target = widget.lyrics.lines[originalIndex].timestamp;
    var shift = 0;
    for (final line in _lines) {
      if (line.text == kGapMarker && line.timestamp <= target) shift++;
    }
    return originalIndex + shift;
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkButtonVisibility);
    widget.currentIndexNotifier.addListener(_onIndexChanged);
    _loadSweepSetting();
    _extractWaveform();

    for (var i = 0; i < _lines.length; i++) {
      _itemKeys[i] = GlobalKey();
    }
  }

  Future<void> _loadSweepSetting() async {
    // Si el padre pasa el valor (toggle reactivo), usarlo directamente.
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

  /// Extrae la energía del audio con ffmpeg (como audio_waveforms del
  /// móvil): PCM mono a 4 kHz → 1000 valores de amplitud media por ventana.
  Future<void> _extractWaveform() async {
    final path = widget.audioPath;
    final ffmpeg = Binaries.ffmpegPath;
    if (path == null || path.isEmpty || ffmpeg == null) return;
    final gen = ++_waveformGen;
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() > 80 * 1024 * 1024) {
        return;
      }
      if (!mounted) return;
      final result = await Process.run(
        ffmpeg,
        ['-i', path, '-ac', '1', '-ar', '4000', '-f', 'f32le', '-'],
        stdoutEncoding: null,
      );
      if (gen != _waveformGen || !mounted) return;
      final bytes = result.stdout as Uint8List;
      final data = _computeEnergyBuckets(bytes, 1000);
      if (mounted && gen == _waveformGen) {
        setState(() => _waveformData = data);
      }
    } catch (e) {
      debugPrint('[LyricsDisplay] Error extracting waveform: $e');
    }
  }

  /// Divide el PCM float32 en `buckets` ventanas y devuelve la amplitud
  /// media (abs) de cada una — la "energía" por tramo de la canción.
  List<double> _computeEnergyBuckets(Uint8List bytes, int buckets) {
    if (bytes.length < 4) return [];
    final sampleCount = bytes.length ~/ 4;
    final byteData = ByteData.sublistView(bytes);
    final result = List<double>.filled(buckets, 0.0);
    for (var b = 0; b < buckets; b++) {
      final startSample = (b * sampleCount) ~/ buckets;
      final endSample = ((b + 1) * sampleCount) ~/ buckets;
      if (endSample <= startSample) continue;
      var sum = 0.0;
      for (var i = startSample; i < endSample; i++) {
        sum += byteData.getFloat32(i * 4, Endian.little).abs();
      }
      result[b] = sum / (endSample - startSample);
    }
    return result;
  }

  /// Progreso de la línea por energía acumulada del audio (igual que
  /// _getWaveformProgress de forawn_mobile). Devuelve -1 si no hay datos.
  double _getWaveformProgress(int displayIndex, Duration position) {
    final duration = widget.durationNotifier?.value;
    if (_waveformData.isEmpty ||
        duration == null ||
        duration.inMilliseconds == 0) {
      return -1.0;
    }
    final line = _lines[displayIndex];
    final startMs = line.timestamp.inMilliseconds;
    final endMs = displayIndex < _lines.length - 1
        ? _lines[displayIndex + 1].timestamp.inMilliseconds
        : duration.inMilliseconds;
    final currentMs = (position - widget.lyricsOffset).inMilliseconds;
    final totalSongMs = duration.inMilliseconds;

    if (currentMs <= startMs) return 0.0;
    if (currentMs >= endMs) return 1.0;

    final startIndex = (startMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);
    final endIndex = (endMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);
    final currentIndex = (currentMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);

    if (startIndex >= endIndex) return -1.0;

    var totalEnergy = 0.0;
    var currentEnergy = 0.0;
    for (var i = startIndex; i <= endIndex; i++) {
      final energy = _waveformData[i].abs() + 0.05;
      totalEnergy += energy;
      if (i <= currentIndex) currentEnergy += energy;
    }
    if (totalEnergy == 0) return -1.0;
    return (currentEnergy / totalEnergy).clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(LyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambiaron las lyrics o el audio (nueva canción), recrear keys y
    // resetear scroll y waveform
    // El toggle de karaoke puede cambiar sin cambiar de canción.
    if (oldWidget.sweepEnabled != widget.sweepEnabled) {
      _loadSweepSetting();
    }
    if (oldWidget.lyrics != widget.lyrics ||
        oldWidget.audioPath != widget.audioPath) {
      _waveformData = [];
      _extractWaveform();
      _itemKeys.clear();
      for (var i = 0; i < _lines.length; i++) {
        _itemKeys[i] = GlobalKey();
      }

      _showSyncButton = false;
      _lastAutoScrolledIndex = -1;
      _userHasScrolled = false;

      _loadSweepSetting();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpTo(0);
        }
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
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex < 0 || !_controller.hasClients) {
      if (_showSyncButton) setState(() => _showSyncButton = false);
      return;
    }

    final key = _itemKeys[displayIndex];
    if (key?.currentContext == null) {
      if (!_showSyncButton) setState(() => _showSyncButton = true);
      return;
    }

    final context = key!.currentContext!;
    final renderObject = context.findRenderObject();
    if (renderObject == null) return;

    final viewport = RenderAbstractViewport.of(renderObject);
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0.5).offset;
    final currentOffset = _controller.offset;
    final viewportHeight = _controller.position.viewportDimension;

    final isFar = (currentOffset - targetOffset).abs() > viewportHeight / 3;

    if (_showSyncButton != isFar) {
      setState(() => _showSyncButton = isFar);
    }
  }

  void _syncToCurrentLine() {
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex >= 0 && _controller.hasClients) {
      final key = _itemKeys[displayIndex];

      void scrollToTarget() {
        if (key?.currentContext != null) {
          Scrollable.ensureVisible(
            key!.currentContext!,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
            alignment: 0.5,
          );
        }
      }

      if (key?.currentContext == null) {
        final estimatedOffset = (displayIndex * 70.0).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        _controller.jumpTo(estimatedOffset);
        WidgetsBinding.instance.addPostFrameCallback((_) => scrollToTarget());
      } else {
        scrollToTarget();
      }

      _lastAutoScrolledIndex = displayIndex;
      _userHasScrolled = false;
      setState(() => _showSyncButton = false);
    }
  }

  void _onIndexChanged() {
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex < 0 || !_controller.hasClients) return;

    if (_userHasScrolled) {
      _checkButtonVisibility();
      return;
    }

    if (displayIndex != _lastAutoScrolledIndex) {
      _lastAutoScrolledIndex = displayIndex;
      final key = _itemKeys[displayIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
          alignment: 0.5,
        );
      } else {
        final estimatedOffset = (displayIndex * 70.0).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        if ((_controller.offset - estimatedOffset).abs() > 500) {
          _controller.jumpTo(estimatedOffset);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (key?.currentContext != null) {
              Scrollable.ensureVisible(
                key!.currentContext!,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOutCubic,
                alignment: 0.5,
              );
            }
          });
        }
      }
    }
  }

  /// Progreso de la línea actual para el sweep, basado en tiempo
  /// (fallback de forawn_mobile sin waveform).
  double _lineProgress(int displayIndex, Duration position) {
    final line = _lines[displayIndex];
    final effectivePos = position - widget.lyricsOffset;
    final start = line.timestamp;

    final realDuration = displayIndex < _lines.length - 1
        ? _lines[displayIndex + 1].timestamp - start
        : null;

    final estimatedMs = ((line.text.length / 12.0) * 1000).toInt() + 1500;
    var durationMs = estimatedMs;
    if (realDuration != null) {
      final realMs = realDuration.inMilliseconds;
      durationMs = estimatedMs < realMs ? estimatedMs : realMs;
      if (durationMs < 1000 && realMs > 1000) durationMs = 1000;
      if (durationMs > realMs) durationMs = realMs;
    }

    if (durationMs <= 0) return 0.0;
    if (effectivePos >= start + Duration(milliseconds: durationMs)) {
      return 1.0;
    }
    if (effectivePos <= start) return 0.0;
    return ((effectivePos - start).inMilliseconds / durationMs).clamp(
      0.0,
      1.0,
    );
  }

  /// Aclara el acento del artwork hacia blanco para el foco de la línea
  /// activa (los acentos extraídos suelen ser darkVibrant).
  Color _readableAccent(Color color) {
    final luminance = color.computeLuminance();
    return luminance < 0.35 ? Color.lerp(color, Colors.white, 0.5)! : color;
  }

  /// Línea con sweep palabra por palabra (modo karaoke).
  Widget _buildKaraokeWords(
    TextStyle style,
    LyricLine line,
    Duration position,
    int displayIndex,
  ) {
    final effectivePos = position - widget.lyricsOffset;
    final accent = widget.accentColor;
    final activeColor = accent == null ? Colors.white : _readableAccent(accent);
    final inactiveColor = accent == null
        ? Colors.white.withValues(alpha: 0.3)
        : _readableAccent(accent).withValues(alpha: 0.3);

    // Timestamps reales por palabra (SyncLRC <mm:ss.xx>): render exacto.
    final words = line.words;
    if (words != null && words.isNotEmpty) {
      final endTime = displayIndex < _lines.length - 1
          ? _lines[displayIndex + 1].timestamp
          : line.timestamp + const Duration(seconds: 5);
      final wordWidgets = <Widget>[];
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        final wStart = w.timestamp;
        final wEnd = i < words.length - 1 ? words[i + 1].timestamp : endTime;

        double wordProgress = 0.0;
        if (effectivePos >= wEnd) {
          wordProgress = 1.0;
        } else if (effectivePos > wStart) {
          final durationMs = (wEnd - wStart).inMilliseconds;
          wordProgress = durationMs > 0
              ? ((effectivePos - wStart).inMilliseconds / durationMs)
                    .clamp(0.0, 1.0)
              : 1.0;
        }

        wordWidgets.add(
          _LyricWord(
            word: w.text + (i < words.length - 1 ? ' ' : ''),
            progress: wordProgress,
            style: style,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
          ),
        );
      }
      return Wrap(
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 0.0,
        runSpacing: 4.0,
        children: wordWidgets,
      );
    }

    // Progreso por energía real del audio (waveform con ffmpeg) si está
    // disponible; si no, estimación por tiempo. Ambos suavizados con
    // 300 ms easeOutCubic (igual que el móvil).
    var lineProgress = _getWaveformProgress(displayIndex, position);
    if (lineProgress < 0) {
      lineProgress = _lineProgress(displayIndex, position);
    }
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: lineProgress, end: lineProgress),
      builder: (context, smoothProgress, _) => _buildKaraokeFromProgress(
        style,
        line.text,
        smoothProgress,
        activeColor,
        inactiveColor,
      ),
    );
  }

  /// Matemática por caracteres con overlap (fallback sin timestamps).
  Widget _buildKaraokeFromProgress(
    TextStyle style,
    String text,
    double lineProgress,
    Color activeColor,
    Color inactiveColor,
  ) {
    final words = text.split(' ');
    final totalChars = text.length;
    final currentCharIndex = lineProgress * totalChars;
    final wordWidgets = <Widget>[];
    var charAccumulator = 0;

    const overlap = 0.5;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final wordLen = word.length;
      final wordStartChar = charAccumulator;
      final wordEndChar = wordStartChar + wordLen;

      double wordProgress = 0.0;
      if (currentCharIndex >= wordEndChar + overlap) {
        wordProgress = 1.0;
      } else if (currentCharIndex <= wordStartChar - overlap) {
        wordProgress = 0.0;
      } else {
        final localCurrent = currentCharIndex - (wordStartChar - overlap);
        final localTotal = wordLen + (overlap * 2);
        wordProgress = (localCurrent / localTotal).clamp(0.0, 1.0);
      }

      wordWidgets.add(
        _LyricWord(
          word: word + (i < words.length - 1 ? ' ' : ''),
          progress: wordProgress,
          style: style,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        ),
      );

      charAccumulator += wordLen + (i < words.length - 1 ? 1 : 0);
    }

    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0.0,
      runSpacing: 4.0,
      children: wordWidgets,
    );
  }

  /// Línea estática (palabras en un solo color) — mantiene el mismo
  /// layout Wrap que la línea karaoke para que no salte el texto.
  Widget _buildStaticWords(
    TextStyle style,
    String text, {
    required bool isCurrent,
  }) {
    final accent = widget.accentColor;
    final words = text.split(' ');
    final color = isCurrent
        ? (accent == null ? Colors.white : _readableAccent(accent))
        : (accent == null
              ? Colors.white.withValues(alpha: 0.5)
              : _readableAccent(accent).withValues(alpha: 0.5));
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0.0,
      runSpacing: 4.0,
      children: [
        for (var i = 0; i < words.length; i++)
          Text(
            words[i] + (i < words.length - 1 ? ' ' : ''),
            style: style.copyWith(color: color),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context);
    return Stack(
      children: [
        ShaderMask(
          shaderCallback: (rect) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.3, 0.7, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.direction != ScrollDirection.idle) {
                _userHasScrolled = true;
              }
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
                    final displayIndex = _mapToDisplayIndex(currentIndex);
                    final isCurrent = index == displayIndex;
                    final line = _lines[index];

                    final baseStyle = TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: isCurrent
                          ? (widget.accentColor == null
                                ? Colors.white
                                : _readableAccent(widget.accentColor!))
                          : (widget.accentColor == null
                                ? Colors.white.withValues(alpha: 0.5)
                                : _readableAccent(
                                    widget.accentColor!,
                                  ).withValues(alpha: 0.5)),
                      height: 1.3,
                      letterSpacing: 0.5,
                      shadows: isCurrent
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [],
                    );

                    final Widget lineContent;
                    if (isCurrent && _isSweepEnabled) {
                      lineContent = ValueListenableBuilder<Duration>(
                        valueListenable: widget.positionNotifier,
                        builder: (context, position, _) {
                          return _buildKaraokeWords(
                            baseStyle,
                            line,
                            position,
                            index,
                          );
                        },
                      );
                    } else {
                      lineContent = _buildStaticWords(
                        baseStyle,
                        line.text,
                        isCurrent: isCurrent,
                      );
                    }

                    return MouseRegion(
                      cursor: widget.onTap != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: GestureDetector(
                        onTap: widget.onTap != null
                            ? () => widget.onTap!(line.timestamp)
                            : null,
                        child: Container(
                          key: _itemKeys[index],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          child: ImageFiltered(
                            imageFilter: isCurrent
                                ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
                                : ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                            child: lineContent,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),

        // Sync Button
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
                      horizontal: 24,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sync, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          l10n.syncLyrics,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Palabra con relleno por progreso (modo karaoke, forawn_mobile).
class _LyricWord extends StatelessWidget {
  final String word;
  final double progress;
  final TextStyle style;
  final Color activeColor;
  final Color inactiveColor;

  const _LyricWord({
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
    } else if (progress <= 0.0) {
      return Text(word, style: style.copyWith(color: inactiveColor));
    }

    // Acelerador visual de progreso para que la última letra se ilumine
    final visualProgress = (progress * 1.25).clamp(0.0, 1.0);

    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          colors: [
            activeColor,
            activeColor.withValues(alpha: 0.5),
            inactiveColor,
          ],
          stops: [
            (visualProgress - 0.2).clamp(0.0, 1.0),
            visualProgress,
            (visualProgress + 0.2).clamp(0.0, 1.0),
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


