import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/track.dart';
import 'audio_cache_service.dart';

/// App-lifetime playlist downloader. Lives above [AudioCacheService] so the
/// batch keeps running after the playlist screen is closed: the UI only
/// subscribes, it never owns the process.
///
/// - The whole batch (queue) is global; queuing a new playlist replaces the
///   pending-but-not-started tracks and appends, so rapid re-taps don't spawn
///   parallel batches.
/// - Per-track progress (0..1) is exposed via [progressFor] and a global
///   change notifier drives ListenableBuilder rows.
class PlaylistDownloadService extends ChangeNotifier {
  PlaylistDownloadService(this._cache);
  final AudioCacheService _cache;

  /// Batch sequence token: incremented each time [downloadPlaylist] is called,
  /// used to drop stale loop iterations of the previous batch.
  int _batchToken = 0;

  /// Download state per videoId. Tracks leave the map when the whole batch
  /// finishes (success or error) — [TrackDownloadStatus.done] entries stay
  /// until then so rows can flash their final state.
  final Map<String, _DownloadState> _states = {};

  // Track ids whose last attempt in this batch failed.
  final Set<String> _failed = {};

  // Tracks queued behind the currently active one.
  final List<Track> _pending = [];

  // Batch bookkeeping for "done" detection.
  int _batchRemaining = 0;
  bool _batchRunning = false;

  String? _activeId;
  double? _activeProgress;

  /// Currently downloading videoId (null when idle).
  String? get activeId => _activeId;

  /// Progress (0..1) of the currently downloading track.
  double? get activeProgress => _activeProgress;

  /// True while any playlist download is running.
  bool get isRunning => _batchRunning;

  /// Number of tracks waiting in the queue.
  int get pendingCount => _pending.length;

  /// VideoIds known-failed in this batch (shown as error state, not done).
  Set<String> get failedIds => Set.unmodifiable(_failed);

  /// Progress snapshot for a row: null = idle, 0..1 = downloading,
  /// 1.0 = just finished this batch.
  double? progressFor(String videoId) {
    final s = _states[videoId];
    if (s == null) return null;
    if (s.status == _Status.downloading) return _activeProgress;
    if (s.status == _Status.queued) return 0.0;
    if (s.status == _Status.done) return 1.0;
    return null;
  }

  /// True if this track is queued or downloading right now.
  bool isActive(String videoId) {
    final s = _states[videoId];
    return s != null &&
        (s.status == _Status.queued || s.status == _Status.downloading);
  }

  /// True if the last batch attempt for this track failed.
  bool isFailed(String videoId) => _failed.contains(videoId);

  /// Queue a whole playlist for offline download. Tracks already cached are
  /// skipped; the rest are downloaded sequentially in the background.
  ///
  /// Returns the number of tracks actually queued (excluding cached ones).
  Future<int> downloadPlaylist(List<Track> tracks) async {
    final toQueue = <Track>[];
    for (final t in tracks) {
      if (isActive(t.id)) continue;
      if (await _cache.cachedPath(t.id) != null) continue;
      toQueue.add(t);
    }
    if (toQueue.isEmpty) return 0;

    final token = ++_batchToken;
    for (final t in toQueue) {
      _states[t.id] = _DownloadState(status: _Status.queued, token: token);
    }
    _pending.addAll(toQueue);
    _batchRemaining += toQueue.length;
    _batchRunning = true;
    notifyListeners();
    unawaited(_runBatch(token));
    return toQueue.length;
  }

  Future<void> _runBatch(int token) async {
    // A single pump drains the shared queue; newer batches just appended to
    // it, so only one loop must be alive at a time.
    if (_states.isEmpty) return;
    // Guard: only the first caller for a "generation" pumps the queue.
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        if (token != _batchToken && _pending.isEmpty) break;
        final track = _pending.removeAt(0);
        final state = _states[track.id];
        if (state == null || state.status != _Status.queued) continue;

        _activeId = track.id;
        _activeProgress = 0.0;
        state.status = _Status.downloading;
        notifyListeners();

        try {
          await _downloadOne(track);
          _failed.remove(track.id);
          state.status = _Status.done;
        } catch (_) {
          state.status = _Status.failed;
          _failed.add(track.id);
        }
        _activeId = null;
        _activeProgress = null;
        _batchRemaining--;
        notifyListeners();

        // Drop terminal states once nothing is left, so `progressFor`
        // returns null on the next batch and badges re-derive from disk.
        if (_batchRemaining <= 0 && _pending.isEmpty) {
          _endBatch(token);
          break;
        }
      }
    } finally {
      _pumping = false;
      // Cancel path: queue emptied while idle — close the batch too.
      if (_pending.isEmpty && _activeId == null && _batchRunning) {
        _endBatch(token);
      }
    }
  }

  void _endBatch(int token) {
    // Clear every state, not just this token's: chained batches share the
    // queue, and at batch end all remaining states are terminal anyway.
    _states.clear();
    _failed.clear();
    _batchRunning = false;
    _batchToken++; // invalidate stale loops
    notifyListeners();
  }

  bool _pumping = false;

  // Download one track in the background via AudioCacheService.preload and
  // mirror the service's per-id progress into the active row. preload()
  // swallows errors internally, so completion is verified against disk.
  Future<void> _downloadOne(Track track) async {
    void onProgress() {
      final p = _cache.backgroundProgress.value[track.id];
      if (p != null && p > (_activeProgress ?? 0)) {
        _activeProgress = p;
        notifyListeners();
      }
    }

    _cache.backgroundProgress.addListener(onProgress);
    try {
      await _cache.preload(track.id, title: track.title);
      if (await _cache.cachedPath(track.id) == null) {
        throw Exception('download did not produce a file');
      }
    } finally {
      _cache.backgroundProgress.removeListener(onProgress);
    }
  }

  /// Cancel everything queued (not yet started). The active download
  /// continues to completion — AudioCacheService owns it.
  void cancelQueued() {
    for (final t in List<Track>.of(_pending)) {
      _states.remove(t.id);
    }
    _pending.clear();
    _batchRemaining = _activeId != null ? 1 : 0;
    if (_pending.isEmpty && _activeId == null) {
      _batchRunning = false;
    }
    notifyListeners();
  }
}

enum _Status { queued, downloading, done, failed }

class _DownloadState {
  _DownloadState({required this.status, required this.token});
  _Status status;
  final int token;
}
