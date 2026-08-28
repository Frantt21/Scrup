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

/// Detects silence gaps in cached audio (ffmpeg silencedetect) and
/// auto-skips them during playback, like YouTube's "skip silence".
class SilenceSkipService extends ChangeNotifier {
  SilenceSkipService(this._player, this._cache, this._settings) {
    _trackSub = _player.currentTrack.listen(_onTrackChanged);
    _playingSub = _player.playing.listen((p) => _playing = p);
    _playing = _player.isPlaying;
    _settings.skipSilenceEnabled.addListener(_onEnabledChanged);
    _pollTimer = Timer.periodic(_pollInterval, (_) => _checkPosition());
    // Analyze already-loaded track (restored session).
    final current = _player.currentTrackValue;
    if (current != null) _prepare(current.id);
  }

  static const _pollInterval = Duration(milliseconds: 50);

  static const _minGapToSkip = Duration(seconds: 2);

  static const _tailGuard = Duration(milliseconds: 120);

  static const _detectArgs = 'silencedetect=noise=-40dB:d=1';

  static const _retryDelay = Duration(seconds: 12);
  static const _maxRetries = 5;

  // SponsorBlock: collaborative DB of non-music segments per YouTube video.
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

  final Map<String, List<SilenceGap>> _sbGaps = {};

  final Map<String, List<SilenceGap>> _gapsByTrack = {};

  // Provisional analysis from partial download (.part file).
  final Map<String, List<SilenceGap>> _provisionalGaps = {};
  final Set<String> _provisionalDone = {};
  String? _analyzingId;

  bool _playing = false;

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

  // Non-music intro duration from SponsorBlock (used for lyrics offset).
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
    if (track == null) return;
    // Defer 200ms to avoid competing with artwork load.
    Timer(const Duration(milliseconds: 200), () {
      if (_player.currentTrackValue?.id == track.id) {
        _prepare(track.id);
      }
    });
  }

  // Fetch SponsorBlock always (feeds lyrics offset), analyze acoustics
  // only when skip-silence is enabled.
  void _prepare(String trackId) {
    unawaited(_fetchSponsorBlock(trackId));
    if (!_settings.skipSilenceEnabled.value) return;
    unawaited(_analyze(trackId));
  }

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
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _analyze(String trackId) async {
    if (_gapsByTrack.containsKey(trackId) || _analyzingId == trackId) return;
    _analyzingId = trackId;
    try {
      var path = await _cache.cachedPath(trackId);
      var provisional = false;
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
      );        if (provisional) _scheduleRetry(trackId);
    } catch (_) {} finally {
      if (_analyzingId == trackId) _analyzingId = null;
    }
  }

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

  // Polls position periodically and skips gaps. Priority: SponsorBlock
  // → acoustic analysis → provisional (.part).
  void _checkPosition() {
    if (!_settings.skipSilenceEnabled.value || !_playing) return;
    final track = _player.currentTrackValue;
    if (track == null) return;
    final pos = _player.positionValue;
    if (_trySkip(_sbGaps[track.id], track.id, pos, curated: true)) return;
    final acoustic = _gapsByTrack[track.id] ?? _provisionalGaps[track.id];
    _trySkip(acoustic, track.id, pos, curated: false);
  }

  // Returns true if position fell inside a gap (skipped or decided not to).
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
      final durationMs = _player.durationValue?.inMilliseconds;
      if (durationMs != null && target.inMilliseconds > durationMs - 200) {
        return true;
      }
      if (pos >= target) target = pos;
      final key = '$trackId:${gap.start.inMilliseconds}';
      final now = DateTime.now();
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

  // Parses ffmpeg silencedetect output into SilenceGap list.
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
              ((secs <= 0 ? 0 : secs) * Duration.microsecondsPerSecond).round(),
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

  // Parses SponsorBlock /api/skipSegments JSON response.
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
            Duration(
              microseconds: (s * Duration.microsecondsPerSecond).round(),
            ),
            Duration(
              microseconds: (e * Duration.microsecondsPerSecond).round(),
            ),
          ),
        );
      }
      return gaps;
    } catch (_) {
      return const [];
    }
  }
}
