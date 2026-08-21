import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/binaries.dart';
import '../core/track.dart';
import 'audio_cache_service.dart';
import 'player_service.dart';
import 'settings_store.dart';

/// Un tramo silencioso detectado en el audio local.
class SilenceGap {
  final Duration start;
  final Duration end;

  const SilenceGap(this.start, this.end);

  bool contains(Duration t) => t >= start && t < end;
}

/// Detecta tramos de silencio en el audio CACHEADO (ffmpeg `silencedetect`)
/// y los salta automáticamente durante la reproducción (como el "omitir
/// silencios" de YouTube): cuando la posición entra en un hueco largo, hace
/// seek al final del hueco para que suene solo la música.
///
/// - La posición se sondea cada [_pollInterval] leyendo
///   [PlayerService.positionValue] (el valor interno del player NO está
///   throttleado; el stream sí, a ~250 ms, que se oiría como un bache de
///   silencio antes del salto).
/// - Solo analiza archivos locales completos (el caché); mientras la pista
///   descarga en streaming se reintenta periódicamente hasta que aparece.
/// - Solo se saltan huecos ≥ [_minGapToSkip] (los silencios musicales
///   cortos entre frases quedan intactos).
/// - Best-effort total: cualquier fallo deja la reproducción normal.
class SilenceSkipService {
  SilenceSkipService(this._player, this._cache, this._settings) {
    _trackSub = _player.currentTrack.listen(_onTrackChanged);
    _playingSub = _player.playing.listen((p) => _playing = p);
    _playing = _player.isPlaying;
    // Reaccionar al toggle EN VIVO: activarlo con la canción ya sonando
    // también arranca el análisis de la pista actual.
    _settings.skipSilenceEnabled.addListener(_onEnabledChanged);
    _pollTimer = Timer.periodic(_pollInterval, (_) => _checkPosition());
    // Analizar la pista ya cargada (sesión restaurada al arrancar).
    final current = _player.currentTrackValue;
    if (current != null && _settings.skipSilenceEnabled.value) {
      unawaited(_analyze(current.id));
    }
  }

  /// Frecuencia de sondeo de posición: 50 ms ⇒ el silencio se percibe como
  /// mucho ~80 ms antes del salto (imperceptible junto a la latencia del
  /// propio seek).
  static const _pollInterval = Duration(milliseconds: 50);

  /// Huecos más cortos que esto NUNCA se saltan (respiraciones musicales).
  static const _minGapToSkip = Duration(seconds: 2);

  /// Margen antes del fin del hueco donde aterrizamos.
  static const _tailGuard = Duration(milliseconds: 120);

  /// Umbral y duración mínima que le pasamos a silencedetect: por debajo de
  /// -40 dB y silencios de ≥1 s cuentan como silencio DETECTABLE (el salto
  /// real lo filtra [_minGapToSkip]).
  static const _detectArgs = 'silencedetect=noise=-40dB:d=1';

  /// Reintentos de análisis mientras la pista descarga en streaming
  /// (progresivo): cada 12 s hasta 5 veces (~1 min de descarga cubierto).
  static const _retryDelay = Duration(seconds: 12);
  static const _maxRetries = 5;

  final PlayerService _player;
  final AudioCacheService _cache;
  final SettingsStore _settings;

  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _pollTimer;
  Timer? _retryTimer;
  int _retryCount = 0;

  /// Análisis por pista (memoria de sesión: re-analizar es barato pero
  /// innecesario dentro de la misma sesión).
  final Map<String, List<SilenceGap>> _gapsByTrack = {};
  String? _analyzingId;

  bool _playing = false;

  /// Anti-bucle: último salto (pista+gap) y cuándo; evita re-seeks por
  /// lecturas de posición antiguas en vuelo tras el seek.
  String? _lastSkipKey;
  DateTime _lastSkipAt = DateTime.fromMillisecondsSinceEpoch(0);

  void dispose() {
    _trackSub?.cancel();
    _playingSub?.cancel();
    _settings.skipSilenceEnabled.removeListener(_onEnabledChanged);
    _pollTimer?.cancel();
    _retryTimer?.cancel();
  }

  void _onEnabledChanged() {
    _retryTimer?.cancel();
    _retryCount = 0;
    if (!_settings.skipSilenceEnabled.value) return;
    final current = _player.currentTrackValue;
    if (current != null) unawaited(_analyze(current.id));
  }

  void _onTrackChanged(Track? track) {
    _retryTimer?.cancel();
    _retryCount = 0;
    if (track == null || !_settings.skipSilenceEnabled.value) return;
    _analyze(track.id);
  }

  Future<void> _analyze(String trackId) async {
    if (_gapsByTrack.containsKey(trackId) || _analyzingId == trackId) return;
    _analyzingId = trackId;
    try {
      final path = await _cache.cachedPath(trackId);
      // Descarga progresiva en curso: reintentar periódicamente mientras la
      // pista siga siendo la actual (el archivo completo queda en caché).
      if (path == null) {
        if (_retryCount >= _maxRetries ||
            _player.currentTrackValue?.id != trackId) {
          return;
        }
        _retryCount++;
        _retryTimer?.cancel();
        _retryTimer = Timer(_retryDelay, () {
          if (_player.currentTrackValue?.id == trackId &&
              !_gapsByTrack.containsKey(trackId)) {
            unawaited(_analyze(trackId));
          }
        });
        return;
      }
      final ffmpeg = Binaries.ffmpegPath;
      if (ffmpeg == null) return;
      final res = await Process.run(ffmpeg, [
        '-hide_banner',
        '-nostats',
        '-i',
        path,
        '-af',
        _detectArgs,
        '-f',
        'null',
        '-',
      ]).timeout(const Duration(seconds: 60));
      final gaps = parseSilences(res.stderr.toString());
      _gapsByTrack[trackId] = gaps;
      if (gaps.isNotEmpty) {
        debugPrint(
          '[Scrup] SilenceSkip: ${gaps.length} hueco(s) en $trackId '
          '[${gaps.map((g) => '${g.start.inSeconds}-${g.end.inSeconds}s').join(', ')}]',
        );
      }
    } catch (_) {
      // Best-effort: sin análisis simplemente no se salta nada.
    } finally {
      if (_analyzingId == trackId) _analyzingId = null;
    }
  }

  /// Sondeo de posición (cada [_pollInterval]): si estamos DENTRO de un
  /// hueco saltable, seek al final del mismo.
  void _checkPosition() {
    if (!_settings.skipSilenceEnabled.value || !_playing) return;
    final track = _player.currentTrackValue;
    if (track == null) return;
    final gaps = _gapsByTrack[track.id];
    if (gaps == null || gaps.isEmpty) return;
    final pos = _player.positionValue;
    for (final gap in gaps) {
      if (!gap.contains(pos)) continue;
      if (gap.end - gap.start < _minGapToSkip) continue;
      final target = gap.end - _tailGuard;
      if (pos >= target) continue;
      final key = '${track.id}:${gap.start.inMilliseconds}';
      // Mismo salto hace <3s: es una lectura vieja post-seek, ignorar.
      if (_lastSkipKey == key &&
          DateTime.now().difference(_lastSkipAt) < const Duration(seconds: 3)) {
        return;
      }
      _lastSkipKey = key;
      _lastSkipAt = DateTime.now();
      debugPrint(
        '[Scrup] SilenceSkip: saltando ${gap.start.inSeconds}-'
        '${gap.end.inSeconds}s → ${target.inMilliseconds}ms',
      );
      unawaited(_player.seek(target));
      return;
    }
  }

  /// Parsea la salida de `silencedetect`: pares
  /// `[silencedetect @ ...] silence_start: X` / `silence_end: Y | ...`.
  /// Los `silence_start` negativos (silencio desde 0) se clampan a cero; un
  /// `silence_start` sin fin (silencio hasta EOF) se descarta por seguridad.
  static List<SilenceGap> parseSilences(String output) {
    final startRe = RegExp(r'silence_start:\s*(-?[\d.]+)');
    final endRe = RegExp(r'silence_end:\s*([\d.]+)');
    final gaps = <SilenceGap>[];
    Duration? start;
    for (final line in output.split('\n')) {
      final s = startRe.firstMatch(line);
      if (s != null) {
        final secs = double.parse(s.group(1)!);
        start = Duration(
          microseconds:
              ((secs <= 0 ? 0 : secs) * Duration.microsecondsPerSecond)
                  .round(),
        );
        continue;
      }
      final e = endRe.firstMatch(line);
      if (e != null && start != null) {
        final end = Duration(
          microseconds:
              (double.parse(e.group(1)!) * Duration.microsecondsPerSecond)
                  .round(),
        );
        if (end > start) gaps.add(SilenceGap(start, end));
        start = null;
      }
    }
    return gaps;
  }
}
