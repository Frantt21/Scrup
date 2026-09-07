import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Diagnostic instrumentation for the accent/palette pipeline and transitions (logcat output: `adb logcat -d | grep SCPR`).
///
/// ALL instrumentation is OFF for the clean release: no SCPR logs, no jank monitor, no frame/rebuild counters, no build profiler, and no performance overlay on the app. The code stays, but with `const false` the compiler removes it in release.
const bool kPaletteLog = false;  /// Shows the performance graph (UI/GPU threads) over the app.
const bool kShowPerfOverlay = false;  /// Logs to logcat every frame that exceeds ~2 vsyncs (SCPR[JANK] with build and raster times).
const bool kJankLog = false;  /// Flutter build profiler (DEBUG ONLY): logs every widget built with its time.
const bool kProfileBuilds = false;  /// Counter of frames PRODUCED every 5s (SCPR[FRAMES]).
const bool kFrameCount = false;  /// Rebuild counters per widget (SCPR[BUILDS] every 5s).
const bool kBuildCount = false;

/// EXPERIMENTO: sin letras (no fetch, no ticker de suavizado, no rebuilds).
/// El contenedor/sheet se conserva (misma geometría) pero vacío.
/// VEREDICTO: no mueven el estado estable; devueltas con single-flight.
/// Flag apagado.
const bool kNoLyrics = false;

/// EXPERIMENTO: sin artwork (CoverImage siempre fallback, sin descargas ni
/// precaches de portadas). Siguiente ronda de ablación; apagado por ahora.
const bool kNoArtwork = false;  /// Threshold (ms) of the build watchdog in overlay/mini/lyrics: if building the widget exceeds this, it is logged as SCPR[PERF].
const int kBuildWatchdogMs = 12;  /// EXPERIMENTO: turns off ALL the accent system (extraction, prefetches, SETs, re-theme). Surfaces stay flat black. If the lag disappears, the culprit is the transition; if it persists, it is something else. VERDICT: culprit confirmed -> flag off, accent restored.
const bool kFlatBlackPlayer = false;  /// EXPERIMENTO: hides the home recent tracks (song grid + playlist row) and does not subscribe to their streams. Every track change fires `recordPlay` -> re-emits recent tracks -> rebuild of the grid. RESOLVED another way (debounce outside the window): flag off.
const bool kHideHomeRecents = false;  /// EXPERIMENTO: does NOT mount the audio stream (`_player.open`/`play`). The full pipeline still runs (queue, resolve, enrich, publish -> artwork, accent and lyrics load) but playback is SIMULATED with a ticker (playing + advancing position) to measure Hz with only colors, artwork and lyrics loading. If Hz do not die with this, the culprit of the jank is audio mounting/decoding. OFF: audio is mounted normally again (verdict: the culprit of the transition jank was the EAGER preview of covers, not the audio).
const bool kNoAudioMount = false;

final DateTime _boot = DateTime.now();

/// `SCPR[TAG +<ms desde arranque>] mensaje`.
void appLog(String tag, String msg) {
  if (!kPaletteLog) return;
  final ms = DateTime.now().difference(_boot).inMilliseconds;
  debugPrint('SCPR[$tag +${ms}ms] $msg');
}

/// `#aarrggbb` o `null`.
String colorHex(Color? c) =>
    c == null ? 'null' : '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

/// Acorta URLs largas de artwork para logs legibles.
String shortUrl(String? url) {
  if (url == null || url.isEmpty) return 'null';
  final noQuery = url.split('?').first;
  return noQuery.length <= 28 ? noQuery : '…${noQuery.substring(noQuery.length - 28)}';
}

/// Acorta ids de pista.
String shortId(String? id) {
  if (id == null || id.isEmpty) return 'null';
  return id.length <= 10 ? id : id.substring(0, 10);
}

/// Registra el monitor de frames perdidos. Llamar una vez en `main()`.
void installJankMonitor() {
  if (!kJankLog) return;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMilliseconds;
      // >34ms ≈ más de 2 vsyncs a 60Hz: build o raster se comieron frames.
      if (total > 34) {
        appLog(
          'JANK',
          'build=${t.buildDuration.inMilliseconds}ms '
          'raster=${t.rasterDuration.inMilliseconds}ms total=${total}ms',
        );
      }
    }
  });
}

/// Contadores de rebuilds por widget (ver [countBuild]).
final Map<String, int> _buildCounts = {};

/// Cuenta UN rebuild de [name]. Barato (un map). Solo con [kBuildCount].
void countBuild(String name) {
  if (!kBuildCount) return;
  _buildCounts[name] = (_buildCounts[name] ?? 0) + 1;
}

/// Cuenta frames producidos cada 5s sin forzar ninguno (el callback se
/// re-registra solo cuando HAY frame). Llamar una vez en `main()`.
void installFrameCounter() {
  if (!kFrameCount && !kBuildCount) return;
  var count = 0;
  void tick(Duration _) {
    count++;
    SchedulerBinding.instance.addPostFrameCallback(tick);
  }

  SchedulerBinding.instance.addPostFrameCallback(tick);
  Timer.periodic(const Duration(seconds: 5), (_) {
    if (kFrameCount) appLog('FRAMES', '$count frames/5s');
    if (kBuildCount && _buildCounts.isNotEmpty) {
      final ranking = _buildCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      appLog(
        'BUILDS',
        ranking.map((e) => '${e.key}×${e.value}').join(' '),
      );
      _buildCounts.clear();
    }
    count = 0;
  });
}
