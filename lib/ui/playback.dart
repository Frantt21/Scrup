import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/player_service.dart';
import 'widgets/scrup_toasts.dart';

/// Reproduce una pista individual (resuelve la fuente cache-first y la
/// reproduce). El historial lo registra el propio [PlayerService] vía el
/// callback `onPlayed` (cubre también auto-advance y radio).
///
/// Se usa desde cualquier vista (inicio, resultados, playlists).
Future<void> playTrack(BuildContext context, Track track) async {
  final l10n = AppLocalizations.of(context);
  final player = context.read<PlayerService>();
  try {
    await player.playTrack(track);
  } catch (e) {
    showScrupToast(l10n.cantPlay(e.toString()), kind: ScrupToastKind.error);
  }
}

/// Reproduce una lista completa como cola (auto-advance al terminar cada
/// pista). Usado por "Reproducir todas" de las playlists.
///
/// [playlistId] identifica la playlist de la que viene la cola: se marca
/// como la playlist "en reproducción" (indicador del sidebar/detalle).
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
