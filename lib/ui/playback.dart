import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../data/database.dart';
import '../services/player_service.dart';

/// Reproduce una pista individual (resuelve la fuente cache-first, la
/// reproduce y registra el historial). Muestra un SnackBar si falla.
///
/// Se usa desde cualquier vista (inicio, resultados, playlists).
Future<void> playTrack(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  final player = context.read<PlayerService>();
  final db = context.read<AppDatabase>();
  try {
    final played = await player.playTrack(track);
    // Cache de metadatos para la próxima vez (solo si sigue vigente)
    if (played) await db.recordPlay(track);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('No se pudo reproducir: $e')),
    );
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
