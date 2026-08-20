import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/track.dart';
import '../data/database.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/player_service.dart';
import 'widgets/cover_image.dart';
import 'widgets/scrup_toasts.dart';

/// Muestra el modal para añadir [track] a una playlist: un diálogo con las
/// playlists en grid (portada + título) y una celda final para crear una
/// nueva. Compartido entre el buscador, las recientes, el reproductor, etc.
Future<void> showAddToPlaylistDialog(BuildContext context, Track track) async {
  final l10n = AppLocalizations.of(context);
  final db = context.read<AppDatabase>();
  final playlists = await db.watchPlaylists().first;
  // Playlists que ya contienen la pista: se marcan con un check en el modal.
  final containing = await db.playlistIdsContainingTrack(track.id);
  if (!context.mounted) return;

  final selected = await showDialog<int>(
    context: context,
    builder: (ctx) => _AddToPlaylistDialog(
      playlists: playlists,
      containing: containing,
      onCreate: () => _createAndSelect(ctx, db),
    ),
  );
  if (selected == null || !context.mounted) return;
  await db.addToPlaylist(selected, track);
  // Si la playlist seleccionada es la que se está reproduciendo,
  // añadir la canción también a la cola del reproductor.
  final player = context.read<PlayerService>();
  if (player.activePlaylistId.value == selected) {
    player.addToQueue(track);
  }
  showScrupToast(l10n.addedToPlaylist, kind: ScrupToastKind.success);
}

/// Modal de selección: glass oscuro con las playlists en grid de 3 columnas.
class _AddToPlaylistDialog extends StatelessWidget {
  final List<Playlist> playlists;

  /// Playlists que ya contienen la pista (se marcan con un check).
  final Set<int> containing;

  /// Crea una playlist nueva y la devuelve seleccionada (cierra el modal).
  final VoidCallback onCreate;

  const _AddToPlaylistDialog({
    required this.playlists,
    required this.containing,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 560,
        constraints: const BoxConstraints(maxHeight: 520),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
              theme.colorScheme.surfaceContainer.withValues(alpha: 0.92),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera: título + cerrar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.addToPlaylist,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.close,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Grid de playlists (o estado vacío)
            Flexible(
              child: playlists.isEmpty
                  ? _EmptyState(onCreate: onCreate)
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.82,
                          ),
                      itemCount: playlists.length + 1,
                      itemBuilder: (context, i) {
                        if (i == playlists.length) {
                          return _CreateCell(onTap: onCreate);
                        }
                        final playlist = playlists[i];
                        return _PlaylistOptionCell(
                          playlist: playlist,
                          containsTrack: containing.contains(playlist.id),
                          onTap: () => Navigator.pop(context, playlist.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Celda de playlist del modal: portada (artwork) + título. Favoritos usa su
/// diseño especial con corazón. Hover con borde sutil. Si la pista ya está en
/// la playlist se muestra un check sobre la portada y el clic avisa en vez de
/// añadir.
class _PlaylistOptionCell extends StatefulWidget {
  final Playlist playlist;

  /// `true` si la pista ya está en esta playlist (se marca con un check).
  final bool containsTrack;

  final VoidCallback onTap;

  const _PlaylistOptionCell({
    required this.playlist,
    required this.containsTrack,
    required this.onTap,
  });

  @override
  State<_PlaylistOptionCell> createState() => _PlaylistOptionCellState();
}

class _PlaylistOptionCellState extends State<_PlaylistOptionCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = widget.playlist;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () {
          // Ya está: no añadir, avisar para que el usuario no "pierda" el
          // clic sin feedback (el check sobre la portada ya lo advierte).
          if (widget.containsTrack) {
            showScrupToast(
              AppLocalizations.of(context).alreadyInPlaylist,
              kind: ScrupToastKind.info,
            );
            return;
          }
          widget.onTap();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Portada atenuada si la pista ya está (el check la marca)
                  Opacity(
                    opacity: widget.containsTrack ? 0.55 : 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CoverImage(
                        source: playlist.coverUrl,
                        cacheWidth: 200,
                        fallback: playlist.isFavorites
                            ? _favoritesFallback(theme)
                            : _defaultFallback(theme),
                      ),
                    ),
                  ),
                  if (_hovered)
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.6,
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  // Check: la pista ya está en esta playlist
                  if (widget.containsTrack)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.black.withValues(alpha: 0.35),
                          ),
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: widget.containsTrack
                    ? theme.colorScheme.onSurfaceVariant
                    : (playlist.isFavorites
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _favoritesFallback(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.50),
            primary.withValues(alpha: 0.18),
            theme.colorScheme.surfaceContainer,
          ],
        ),
      ),
      child: Icon(Icons.favorite, size: 30, color: primary),
    );
  }

  Widget _defaultFallback(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHigh,
            theme.colorScheme.surfaceContainer,
          ],
        ),
      ),
      child: Icon(
        Icons.queue_music,
        size: 28,
        color: theme.colorScheme.primary.withValues(alpha: 0.45),
      ),
    );
  }
}

/// Celda final que emula una playlist pero es un botón para crear una nueva.
class _CreateCell extends StatelessWidget {
  final VoidCallback onTap;

  const _CreateCell({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.55),
                  ),
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                ),
                child: Center(
                  child: Icon(
                    Icons.add,
                    size: 30,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.newPlaylist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
            Text(
              l10n.newPlaylistHint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Estado vacío: sin playlists aún, con botón para crear la primera.
class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music,
              size: 40,
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.noPlaylistsYet,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.newPlaylist),
            ),
          ],
        ),
      ),
    );
  }
}

/// Crea una playlist y la selecciona en el modal actual (best-effort: si la
/// creación falla, el modal se queda abierto y se avisa con un toast).
Future<void> _createAndSelect(BuildContext ctx, AppDatabase db) async {
  final navigator = Navigator.of(ctx);
  final l10n = AppLocalizations.of(ctx);
  final name = await _promptCreatePlaylist(ctx);
  if (name == null || name.isEmpty) return;
  final int id;
  try {
    id = await db.createPlaylist(name);
  } catch (_) {
    showScrupToast(l10n.cantCreatePlaylist, kind: ScrupToastKind.error);
    return;
  }
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
