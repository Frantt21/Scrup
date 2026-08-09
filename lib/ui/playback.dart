import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../services/player_service.dart';
import 'widgets/scrup_snackbar.dart';

/// Reproduce una pista individual (resuelve la fuente cache-first y la
/// reproduce). El historial lo registra el propio [PlayerService] vía el
/// callback `onPlayed` (cubre también auto-advance y radio).
///
/// Se usa desde cualquier vista (inicio, resultados, playlists).
Future<void> playTrack(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  final player = context.read<PlayerService>();
  try {
    await player.playTrack(track);
  } catch (e) {
    showScrupSnackBar(messenger, 'No se pudo reproducir: $e');
  }
}

/// Reproduce una lista completa como cola (auto-advance al terminar cada
/// pista). Usado por "Reproducir todas" de las playlists.
Future<void> playQueue(
  BuildContext context,
  List<Track> tracks, {
  int startIndex = 0,
}) async {
  final player = context.read<PlayerService>();
  await player.playQueue(tracks, startIndex: startIndex);
}
