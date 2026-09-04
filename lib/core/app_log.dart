import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Logs de depuración del pipeline de acento/paleta y transiciones.
///
/// Salida por logcat: `adb logcat -d | grep SCPR`.
/// Apagados para el release limpio (reactivar con `true` al depurar).
const bool kPaletteLog = false;

/// Muestra la gráfica de rendimiento (hilos UI/GPU) sobre la app.
/// Para cazar frames perdidos a ojo durante las transiciones.
const bool kShowPerfOverlay = false;

/// Loguea por logcat cada frame que exceda ~2 vsynchs (SCPR[JANK] con
/// tiempos de build y raster): permite cazar al culpable sin mirar la
/// pantalla.
const bool kJankLog = false;

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
