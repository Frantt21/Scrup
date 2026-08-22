import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
class SilenceSkipService extends ChangeNotifier {
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
      _prepare(current.id);
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

  /// SponsorBlock (https://sponsor.ajay.app): base de datos COLABORATIVA de
  /// segmentos por video de YouTube. `music_offtopic` son las partes que NO
  /// son parte de la canción (intros habladas, visuales, promos…), que el
  /// detector acústico no puede ver por no ser silencio puro.
  static const _sbHost = 'sponsor.ajay.app';
  static const List<String> _sbCategories = [
    'music_offtopic',
    'intro',
    'outro',
    'sponsor',
    'selfpromo',
    'filler',
  ];

  final PlayerService _player;
  final AudioCacheService _cache;
  final SettingsStore _settings;

  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _pollTimer;
  Timer? _retryTimer;
  int _retryCount = 0;

  /// Segmentos de SponsorBlock por pista (curados por la comunidad:
  /// prioridad sobre el detector acústico).
  final Map<String, List<SilenceGap>> _sbGaps = {};

  /// Análisis por pista (memoria de sesión: re-analizar es barato pero
  /// innecesario dentro de la misma sesión).
  final Map<String, List<SilenceGap>> _gapsByTrack = {};

  /// Análisis PROVISIONAL hecho sobre el `.part` de una descarga en curso:
  /// fiable para el inicio del archivo (intro), se sustituye por el
  /// definitivo cuando la descarga completa queda cacheada.
  final Map<String, List<SilenceGap>> _provisionalGaps = {};
  final Set<String> _provisionalDone = {};
  String? _analyzingId;

  bool _playing = false;

  /// Anti-bucle: último salto (pista+gap) y cuándo; evita re-seeks por
  /// lecturas de posición antiguas en vuelo tras el seek.
  String? _lastSkipKey;
  DateTime _lastSkipAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _trackSub?.cancel();
    _playingSub?.cancel();
    _settings.skipSilenceEnabled.removeListener(_onEnabledChanged);
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  /// Duración del intro NO musical al inicio de la pista según SponsorBlock
  /// (segmento que arranca en los primeros ~2 s): el desfase entre el
  /// comienzo del ARCHIVO y el de la CANCIÓN real. Las letras — sincronizadas
  /// a la canción oficial — deben desplazarse exactamente ese tiempo. Null =
  /// sin datos de SponsorBlock para esta pista.
  ///
  /// Nota: es información del archivo, no del toggle: aplica también con el
  /// omitir-silencios apagado (durante el intro simplemente no hay letra).
  Duration? introEndFor(String? trackId) {
    if (trackId == null) return null;
    final gaps = _sbGaps[trackId];
    if (gaps == null || gaps.isEmpty) return null;
    Duration? best;
    for (final gap in gaps) {
      if (gap.start > const Duration(seconds: 2)) continue;
      if (best == null || gap.end > best) best = gap.end;
    }
    return best;
  }

  void _onEnabledChanged() {
    _retryTimer?.cancel();
    _retryCount = 0;
    if (!_settings.skipSilenceEnabled.value) return;
    final current = _player.currentTrackValue;
    if (current != null) _prepare(current.id);
  }

  void _onTrackChanged(Track? track) {
    _retryTimer?.cancel();
    _retryCount = 0;
    if (track == null || !_settings.skipSilenceEnabled.value) return;
    _prepare(track.id);
  }

  /// Prepara los huecos de UNA pista: primero SponsorBlock (instantáneo y
  /// curado — cubre intros/outros que NO son silencio acústico), y en
  /// paralelo el análisis local con ffmpeg como fallback.
  void _prepare(String trackId) {
    unawaited(_fetchSponsorBlock(trackId));
    unawaited(_analyze(trackId));
  }

  /// Consulta SponsorBlock por el videoId de la pista. Sin segmentos la API
  /// responde 404 "Not Found": se guarda lista vacía para no reconsultar.
  Future<void> _fetchSponsorBlock(String trackId) async {
    if (_sbGaps.containsKey(trackId)) return;
    try {
      final categories = Uri.encodeComponent(jsonEncode(_sbCategories));
      final uri = Uri.parse(
        'https://$_sbHost/api/skipSegments'
        '?videoID=$trackId&categories=$categories',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      final gaps = res.statusCode == 200
          ? parseSkipSegments(res.body)
          : const <SilenceGap>[];
      _sbGaps[trackId] = gaps;
      if (gaps.isNotEmpty) {
        debugPrint(
          '[Scrup] SilenceSkip: SponsorBlock ${gaps.length} segmento(s) '
          'en $trackId '
          '[${gaps.map((g) => '${g.start.inSeconds}-${g.end.inSeconds}s').join(', ')}]',
        );
        // Avisar a los oyentes (la vista de letras corrige su offset con
        // [introEndFor] cuando llegan datos nuevos).
        notifyListeners();
      }
    } catch (_) {
      // Sin red / timeout: queda el detector acústico como fallback.
    }
  }

  Future<void> _analyze(String trackId) async {
    if (_gapsByTrack.containsKey(trackId) || _analyzingId == trackId) return;
    _analyzingId = trackId;
    try {
      var path = await _cache.cachedPath(trackId);
      var provisional = false;
      // Descarga progresiva en curso: el `.part` parcial YA contiene el
      // principio del archivo, así que los silencios del intro se pueden
      // detectar de inmediato. El resultado es PROVISIONAL: cuando la
      // descarga complete, se re-analiza el archivo entero.
      if (path == null) {
        path = await _findPartialFile(trackId);
        provisional = path != null;
        if (path == null ||
            (provisional && _provisionalDone.contains(trackId))) {
          _scheduleRetry(trackId);
          return;
        }
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
      if (provisional) {
        _provisionalGaps[trackId] = gaps;
        _provisionalDone.add(trackId);
      } else {
        _gapsByTrack[trackId] = gaps;
        _provisionalGaps.remove(trackId);
        _provisionalDone.remove(trackId);
      }
      debugPrint(
        '[Scrup] SilenceSkip: ${gaps.length} hueco(s) en $trackId '
        '${provisional ? "(parcial) " : ""}'
        '[${gaps.map((g) => '${g.start.inSeconds}-${g.end.inSeconds}s').join(', ')}]',
      );
      // Resultado provisional: seguir reintentando para analizar el
      // archivo completo en cuanto termine la descarga.
      if (provisional) _scheduleRetry(trackId);
    } catch (_) {
      // Best-effort: sin análisis simplemente no se salta nada.
    } finally {
      if (_analyzingId == trackId) _analyzingId = null;
    }
  }

  /// Busca el `.part` de descarga en curso de [trackId] (el más reciente),
  /// o `null` si no hay. ffmpeg decodifica lo descargado hasta el momento:
  /// suficiente para los silencios del inicio.
  Future<String?> _findPartialFile(String trackId) async {
    try {
      final dir = await _cache.cacheDir();
      String? best;
      DateTime bestTime = DateTime.fromMillisecondsSinceEpoch(0);
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.startsWith('$trackId.') || !name.endsWith('.part')) continue;
        final t = e.lastModifiedSync();
        if (t.isAfter(bestTime)) {
          bestTime = t;
          best = e.path;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// Reintento de análisis (descarga aún en curso o resultado parcial que
  /// falta mejorar con el archivo completo).
  void _scheduleRetry(String trackId) {
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
  }

  /// Sondeo de posición (cada [_pollInterval]): si estamos DENTRO de un
  /// hueco saltable, seek al final del mismo. Prioridad: segmentos curados
  /// de SponsorBlock → análisis acústico definitivo → provisional (.part).
  void _checkPosition() {
    if (!_settings.skipSilenceEnabled.value || !_playing) return;
    final track = _player.currentTrackValue;
    if (track == null) return;
    final pos = _player.positionValue;
    if (_trySkip(_sbGaps[track.id], track.id, pos, curated: true)) return;
    final acoustic = _gapsByTrack[track.id] ?? _provisionalGaps[track.id];
    _trySkip(acoustic, track.id, pos, curated: false);
  }

  /// Busca en [gaps] uno que contenga [pos] y salte a su final. Los gaps
  /// `curated` (SponsorBlock) se respetan sea cual sea su duración; los
  /// acústicos exigen [_minGapToSkip]. Devuelve `true` si consumió la
  /// comprobación (saltó o decidió no saltar).
  bool _trySkip(
    List<SilenceGap>? gaps,
    String trackId,
    Duration pos, {
    required bool curated,
  }) {
    if (gaps == null || gaps.isEmpty) return false;
    for (final gap in gaps) {
      if (!gap.contains(pos)) continue;
      if (!curated && gap.end - gap.start < _minGapToSkip) continue;
      var target = gap.end - _tailGuard;
      // Si el aterrizaje cae al filo del fin del medio, no buscar: el
      // avance natural está a punto de dispararse solo.
      final durationMs = _player.durationValue?.inMilliseconds;
      if (durationMs != null && target.inMilliseconds > durationMs - 200) {
        return true;
      }
      if (pos >= target) target = pos;
      final key = '$trackId:${gap.start.inMilliseconds}';
      final now = DateTime.now();
      // Mismo salto hace <3s: lectura vieja post-seek; y CUALQUIER salto
      // hace <600ms: evita dobles seeks cuando SB y acústico solapan.
      if (_lastSkipKey == key &&
          now.difference(_lastSkipAt) < const Duration(seconds: 3)) {
        return true;
      }
      if (now.difference(_lastSkipAt) < const Duration(milliseconds: 600)) {
        return true;
      }
      _lastSkipKey = key;
      _lastSkipAt = now;
      debugPrint(
        '[Scrup] SilenceSkip: saltando ${curated ? "[SB] " : ""}'
        '${gap.start.inSeconds}-${gap.end.inSeconds}s '
        '→ ${target.inMilliseconds}ms',
      );
      unawaited(_player.seek(target));
      return true;
    }
    return false;
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

  /// Parsea la respuesta JSON de `/api/skipSegments`: lista de
  /// `{segment: [start, end], category, actionType, ...}`. Solo se aceptan
  /// segmentos `actionType: "skip"` de ≥0.5 s (los "poi_highlight" y
  /// fragmentos minúsculos no son saltos).
  static List<SilenceGap> parseSkipSegments(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];
      final gaps = <SilenceGap>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final action = item['actionType'];
        if (action != null && action != 'skip') continue;
        final seg = item['segment'];
        if (seg is! List || seg.length != 2) continue;
        final s = (seg[0] as num?)?.toDouble();
        final e = (seg[1] as num?)?.toDouble();
        if (s == null || e == null || e <= s) continue;
        if (e - s < 0.5) continue;
        gaps.add(
          SilenceGap(
            Duration(microseconds: (s * Duration.microsecondsPerSecond).round()),
            Duration(microseconds: (e * Duration.microsecondsPerSecond).round()),
          ),
        );
      }
      return gaps;
    } catch (_) {
      return const [];
    }
  }
}
