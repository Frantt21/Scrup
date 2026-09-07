import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/player_service.dart';
import 'widgets/scrup_toasts.dart';

/// Play a single track (resolves the source cache-first and plays it). The history is registered by [PlayerService] itself via the `onPlayed` callback (also covers auto-advance and radio).
///
/// It is used from any view (home, results, playlists).
Future<void> playTrack(BuildContext context, Track track) async {
  final l10n = AppLocalizations.of(context);
  final player = context.read<PlayerService>();
  try {
    await player.playTrack(track);
  } catch (e) {
    showScrupToast(l10n.cantPlay(e.toString()), kind: ScrupToastKind.error);
  }
}

/// Play a full list as a queue (auto-advance when each track ends). Used by playlists' "Play all".
///
/// [playlistId] identifies the playlist the queue comes from: it is marked as the playlist "now playing" (sidebar/detail indicator).
Future<void> playQueue(
  BuildContext context,
  List<Track> tracks, {
  int startIndex = 0,
  int? playlistId,
}) async {
  final player = context.read<PlayerService>();
  await player.playQueue(
    tracks,
    startIndex: startIndex,
    playlistId: playlistId,
  );
}
