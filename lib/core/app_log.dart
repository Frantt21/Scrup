import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Logs de depuración del pipeline de acento/paleta y transiciones.
///
/// Salida por logcat: `adb logcat -d | grep SCPR`.
const bool kPaletteLog = true;

/// Muestra la gráfica de rendimiento (hilos UI/GPU) sobre la app.
/// Para cazar frames perdidos a ojo durante las transiciones.
const bool kShowPerfOverlay = true;

/// Loguea por logcat cada frame que exceda ~2 vsynchs (SCPR[JANK] con
/// tiempos de build y raster): permite cazar al culpable sin mirar la
/// pantalla.
const bool kJankLog = true;

/// Perfilador de builds de Flutter (SOLO debug): loguea cada widget
/// construido con su tiempo. Muy verboso; es la red de arrastre para ver
/// QUÉ widget se come los frames.
const bool kProfileBuilds = true;

/// Contador de frames PRODUCIDOS cada 5s (SCPR[FRAMES]): mide la demanda
/// real de frames sin forzar ninguno. En reposo debe tender a ~0-10;
/// si marca cientos, algo sigue pidiendo frames sin parar.
const bool kFrameCount = true;

/// Contadores de rebuilds por widget (SCPR[BUILDS] cada 5s): demuestra QUÉ
/// widgets se reconstruyen sin parar (padre que arrastra a todos los hijos).
const bool kBuildCount = true;

/// EXPERIMENTO: sin letras (no fetch, no ticker de suavizado, no rebuilds).
/// El contenedor/sheet se conserva (misma geometría) pero vacío.
/// VEREDICTO: no mueven el estado estable; devueltas con single-flight.
/// Flag apagado.
const bool kNoLyrics = false;

/// EXPERIMENTO: sin artwork (CoverImage siempre fallback, sin descargas ni
/// precaches de portadas). Siguiente ronda de ablación; apagado por ahora.
const bool kNoArtwork = false;

/// Umbral (ms) del watchdog de build en overlay/mini/letras: si construir
/// el widget supera esto, se loguea SCPR[PERF].
const int kBuildWatchdogMs = 12;

/// EXPERIMENTO: apaga TODO el sistema de acento (extracción, precargas,
/// SETs, re-theme). Las superficies quedan en negro plano. Si el lag
/// desaparece, el culpable es la transición; si persiste, es otra cosa.
/// VEREDICTO: culpable confirmado → flag apagado, acento restaurado.
const bool kFlatBlackPlayer = false;

/// EXPERIMENTO: oculta las recientes de home (grid de canciones + fila de
/// playlists) y no se suscribe a sus streams. Cada cambio de canción dispara
/// `recordPlay` → reemite recientes → rebuild del grid.
/// RESUELTO de otra forma (debounce fuera de ventana): flag apagado.
const bool kHideHomeRecents = false;

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
