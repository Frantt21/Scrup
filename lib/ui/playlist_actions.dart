import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../data/database.dart';
import '../l10n/generated/app_localizations.dart';
import 'widgets/scrup_toasts.dart';

/// Muestra el selector de playlist y añade [track] a la elegida (o a una
/// recién creada). Compartido entre el buscador, las recientes, etc.
Future<void> showAddToPlaylistSheet(BuildContext context, Track track) async {
  final l10n = AppLocalizations.of(context);
  final db = context.read<AppDatabase>();
  final playlists = await db.watchPlaylists().first;
  if (!context.mounted) return;

  final selected = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.addToPlaylist,
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.noPlaylistsYet,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final p in playlists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              onTap: () => Navigator.pop(ctx, p.id),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.newPlaylist),
            onTap: () => _createAndSelect(ctx, db, track),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  await db.addToPlaylist(selected, track);
  showScrupToast(l10n.addedToPlaylist, kind: ScrupToastKind.success);
}

/// Crea una playlist y la selecciona en el bottom sheet actual.
Future<void> _createAndSelect(
  BuildContext ctx,
  AppDatabase db,
  Track track,
) async {
  final navigator = Navigator.of(ctx);
  final name = await _promptCreatePlaylist(ctx);
  if (name == null || name.isEmpty) return;
  final id = await db.createPlaylist(name);
  navigator.pop(id);
}

Future<String?> _promptCreatePlaylist(BuildContext context) {
  final controller = TextEditingController();
  final l10n = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.newPlaylist),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.playlistNamePrompt),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(l10n.create),
        ),
      ],
    ),
  );
}
