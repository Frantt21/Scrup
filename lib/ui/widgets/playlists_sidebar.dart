import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/settings_store.dart';
import 'cover_image.dart';
import 'scrup_snackbar.dart';

/// Ancho fijo del contenedor lateral de playlists.
const double kSidebarWidth = 250;

/// Contenedor lateral flotante tipo glass: ocupa su propio espacio a la
/// izquierda (no se superpone al contenido) y muestra TODAS las playlists.
/// Permite alternar entre vista de LISTA (filas) y CUADRÍCULA (grid de 2
/// columnas). En ambos modos hay un item final que emula una playlist pero
/// es un botón para crear una nueva.
class PlaylistsSidebar extends StatefulWidget {
  /// Playlist abierta actualmente (para resaltarla en la lista). `null` =
  /// ninguna abierta.
  final int? openPlaylistId;

  /// Abre (o cierra, con `null`) el detalle de una playlist.
  final ValueChanged<Playlist?> onSelectPlaylist;

  const PlaylistsSidebar({
    super.key,
    required this.openPlaylistId,
    required this.onSelectPlaylist,
  });

  @override
  State<PlaylistsSidebar> createState() => _PlaylistsSidebarState();
}

class _PlaylistsSidebarState extends State<PlaylistsSidebar> {
  late final Stream<List<Playlist>> _playlistsStream;
  late final Stream<Map<int, int>> _countsStream;
  StreamSubscription<List<Playlist>>? _playlistsSub;
  StreamSubscription<Map<int, int>>? _countsSub;
  List<Playlist> _playlists = const [];
  Map<int, int> _counts = const {};

  /// `true` = cuadrícula (grid de 2 columnas); `false` = lista.
  bool _gridMode = false;

  /// El usuario ya alternó el modo: evita que la carga asíncrona de la
  /// preferencia sobrescriba su elección (carrera de arranque).
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _loadGridMode();
    final db = context.read<AppDatabase>();
    _playlistsStream = db.watchPlaylists();
    _playlistsSub = _playlistsStream.listen((playlists) {
      if (!mounted) return;
      setState(() => _playlists = playlists);
    });
    _countsStream = db.watchPlaylistTrackCounts();
    _countsSub = _countsStream.listen((counts) {
      if (!mounted) return;
      setState(() => _counts = counts);
    });
  }

  /// Restaura el modo guardado (lista/cuadrícula) de la última sesión.
  Future<void> _loadGridMode() async {
    try {
      final saved = await context.read<SettingsStore>().loadSidebarGridMode();
      if (!mounted || saved == null || _userToggled) return;
      setState(() => _gridMode = saved);
    } catch (_) {
      // La preferencia nunca debe romper el arranque del sidebar.
    }
  }

  void _toggleGridMode(bool grid) {
    _userToggled = true;
    setState(() => _gridMode = grid);
    unawaited(context.read<SettingsStore>().saveSidebarGridMode(grid));
  }

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _countsSub?.cancel();
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final data =
        await showDialog<
          ({String name, String? description, String? imagePath})
        >(context: context, builder: (_) => const _CreatePlaylistDialog());
    if (data == null || !mounted) return;
    final name = data.name.trim();
    if (name.isEmpty) return;
    final int id;
    try {
      id = await db.createPlaylist(name);
    } catch (_) {
      if (!mounted) return;
      showScrupSnackBar(messenger, l10n.cantCreatePlaylist);
      return;
    }
    // Descripción y portada: best-effort (si la portada falla, la playlist
    // ya existe y se crea igual, solo sin imagen).
    final description = data.description;
    if (description != null && description.isNotEmpty) {
      try {
        await db.setPlaylistDescription(id, description);
      } catch (_) {}
    }
    final imagePath = data.imagePath;
    if (imagePath != null) {
      try {
        final dest = await copyPlaylistCoverToAppDir(id, imagePath);
        await db.setPlaylistCover(id, dest);
      } catch (_) {
        // Silencioso: la playlist se crea igual sin portada.
      }
    }
    showScrupSnackBar(messenger, l10n.playlistCreated(name));
    // Abrir la recién creada directamente.
    if (!mounted) return;
    final playlist = await db.getPlaylist(id);
    if (mounted && playlist != null) {
      widget.onSelectPlaylist(playlist);
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    // Favoritos es una playlist especial: nunca se borra.
    if (playlist.isFavorites) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deletePlaylistTitle),
        content: Text(l10n.confirmDeletePlaylist(playlist.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await db.deletePlaylist(playlist.id);
    // Si la portada era un archivo local (elegido por el usuario), borrarlo
    // para no dejar huérfanos en playlist_covers/.
    final cover = playlist.coverUrl;
    if (cover != null && CoverImage.isLocalPath(cover)) {
      final file = File(cover);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // Silencioso: el cleanup no debe romper el borrado.
        }
      }
    }
    // Si se eliminó la playlist abierta, cerrar el detalle.
    if (widget.openPlaylistId == playlist.id) {
      widget.onSelectPlaylist(null);
    }
    if (!mounted) return;
    showScrupSnackBar(messenger, l10n.playlistDeleted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Container(
      width: kSidebarWidth,
      // Margen derecho 16 = mismo hueco que el padding del player (16): la
      // separación entre el sidebar y el contenido queda idéntica a la del
      // lado derecho (contenido → borde de la ventana).
      margin: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      // Sombra exterior (fuera del clip para que no se recorte)
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          // Cristal: difumina lo que pase por detrás
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              // Cristal limpio: dos tonos oscuros translúcidos, sin el tinte
              // del artwork (UI más neutro y limpio).
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.55,
                  ),
                  theme.colorScheme.surfaceContainer.withValues(alpha: 0.55),
                ],
              ),
            ),
            child: Material(
              // Transparente para que los ripples se dibujen sobre el cristal
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cabecera: título + toggle lista/cuadrícula
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.playlistsTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        // Toggle lista/cuadrícula: chip compacto con los dos
                        // modos siempre visibles; el activo se resalta en lila.
                        _ViewToggle(
                          gridMode: _gridMode,
                          onChanged: _toggleGridMode,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _gridMode ? _buildGrid(theme) : _buildList(theme),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Vista de lista: filas con miniatura + nombre + conteo y el item de
  /// crear al final.
  Widget _buildList(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        if (_playlists.isEmpty) _emptyState(theme),
        for (final playlist in _playlists)
          _PlaylistRow(
            playlist: playlist,
            count: _counts[playlist.id] ?? 0,
            selected: playlist.id == widget.openPlaylistId,
            onTap: () => widget.onSelectPlaylist(playlist),
            onDelete: () => _deletePlaylist(playlist),
            // Favoritos: diseño especial con corazón y sin borrar.
            showDelete: !playlist.isFavorites,
          ),
        const SizedBox(height: 4),
        _CreatePlaylistTile(onTap: _createPlaylist),
      ],
    );
  }

  /// Vista de cuadrícula: grid de 2 columnas con tarjetas de portada y el
  /// item de crear ocupando una celda.
  Widget _buildGrid(ThemeData theme) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: _playlists.length + 1,
      itemBuilder: (context, i) {
        if (i == _playlists.length) {
          return _CreateGridCell(onTap: _createPlaylist);
        }
        final playlist = _playlists[i];
        return _PlaylistGridCell(
          playlist: playlist,
          count: _counts[playlist.id] ?? 0,
          selected: playlist.id == widget.openPlaylistId,
          onTap: () => widget.onSelectPlaylist(playlist),
          onDelete: () => _deletePlaylist(playlist),
          // Favoritos: diseño especial con corazón y sin borrar.
          showDelete: !playlist.isFavorites,
        );
      },
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.queue_music,
            size: 32,
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).noPlaylists,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            AppLocalizations.of(context).createOneHere,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggle compacto lista/cuadrícula: chip redondeado con los DOS iconos
/// siempre visibles (sin cajas individuales). El modo activo se resalta con
/// el color primario (lila) sobre un fondo sutil.
class _ViewToggle extends StatelessWidget {
  final bool gridMode;
  final ValueChanged<bool> onChanged;

  const _ViewToggle({required this.gridMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(
            context: context,
            icon: Icons.view_list_outlined,
            tooltip: AppLocalizations.of(context).listViewTooltip,
            active: !gridMode,
            onTap: () => onChanged(false),
          ),
          _seg(
            context: context,
            icon: Icons.grid_view_rounded,
            tooltip: AppLocalizations.of(context).gridViewTooltip,
            active: gridMode,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }

  Widget _seg({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: active
          ? theme.colorScheme.primary.withValues(alpha: 0.25)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Icon(
              icon,
              size: 17,
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Fila de playlist (vista lista): miniatura + nombre + nº de canciones, con
/// borrado al hacer hover. La abierta se resalta con el tinte del color
/// primario.
class _PlaylistRow extends StatefulWidget {
  final Playlist playlist;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// `false` en Favoritos: no se muestra el botón de borrar.
  final bool showDelete;

  const _PlaylistRow({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    this.showDelete = true,
  });

  @override
  State<_PlaylistRow> createState() => _PlaylistRowState();
}

class _PlaylistRowState extends State<_PlaylistRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = widget.playlist;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: widget.selected
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _thumb(theme),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: widget.selected
                              ? theme.colorScheme.primary
                              : (playlist.isFavorites
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface),
                        ),
                      ),
                      Text(
                        AppLocalizations.of(context).songCount(widget.count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Espacio reservado para el borrar (oculto en Favoritos):
                // evita que el nombre \"salte\" de ancho en hover.
                if (widget.showDelete)
                  SizedBox(
                    width: 32,
                    child: _hovered
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            visualDensity: VisualDensity.compact,
                            tooltip: AppLocalizations.of(context).delete,
                            color: theme.colorScheme.onSurfaceVariant,
                            onPressed: widget.onDelete,
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumb(ThemeData theme) {
    final favorites = widget.playlist.isFavorites;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 40,
        height: 40,
        child: CoverImage(
          source: widget.playlist.coverUrl,
          cacheWidth: 120,
          fallback: favorites
              // Favoritos: miniatura especial con corazón y degradado cálido.
              ? _favoritesFallback(theme)
              : Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
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
                    size: 18,
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ),
        ),
      ),
    );
  }

  /// Placeholder de Favoritos: degradado cálido con corazón, distinto del
  /// por defecto.
  Widget _favoritesFallback(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: 0.45),
            primary.withValues(alpha: 0.15),
            theme.colorScheme.surfaceContainer,
          ],
        ),
      ),
      child: Icon(Icons.favorite, size: 18, color: primary),
    );
  }
}

/// Tarjeta de playlist (vista cuadrícula): portada grande + nombre y conteo
/// debajo. Hover con borde y borrar; la abierta se resalta.
class _PlaylistGridCell extends StatefulWidget {
  final Playlist playlist;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// `false` en Favoritos: no se muestra el botón de borrar.
  final bool showDelete;

  const _PlaylistGridCell({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    this.showDelete = true,
  });

  @override
  State<_PlaylistGridCell> createState() => _PlaylistGridCellState();
}

class _PlaylistGridCellState extends State<_PlaylistGridCell> {
  bool _hovered = false;

  /// Placeholder de Favoritos: degradado cálido con corazón grande.
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
      child: Icon(Icons.favorite, size: 32, color: primary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = widget.playlist;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CoverImage(
                      source: playlist.coverUrl,
                      cacheWidth: 200,
                      fallback: playlist.isFavorites
                          // Favoritos: portada especial con corazón y
                          // degradado cálido (no el por defecto).
                          ? _favoritesFallback(theme)
                          : Container(
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
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                            ),
                    ),
                  ),
                  // Resaltado: borde si está seleccionada o en hover
                  if (_hovered || widget.selected)
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: widget.selected ? 0.9 : 0.5,
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  if (_hovered && widget.showDelete)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onDelete,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_outline,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
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
                color: widget.selected
                    ? theme.colorScheme.primary
                    : (playlist.isFavorites
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface),
              ),
            ),
            Text(
              AppLocalizations.of(context).songCount(widget.count),
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

/// Item final que emula una playlist pero es un botón para crear una nueva
/// (vista lista).
class _CreatePlaylistTile extends StatelessWidget {
  final VoidCallback onTap;

  const _CreatePlaylistTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.55),
                  ),
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(
                  Icons.add,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).newPlaylist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Celda que emula una playlist pero es un botón para crear una nueva
/// (vista cuadrícula). Usa EXACTAMENTE la misma estructura que las celdas de
/// playlist (bloque de portada + dos líneas de texto) para que las
/// dimensiones coincidan.
class _CreateGridCell extends StatelessWidget {
  final VoidCallback onTap;

  const _CreateGridCell({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mismo bloque que la portada de las celdas de playlist
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
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).newPlaylist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            AppLocalizations.of(context).newPlaylistHint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog de creación de playlist: nombre, descripción opcional y portada
/// opcional elegida desde archivo (con vista previa).
class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog();

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  String? _imagePath;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final images = XTypeGroup(
      label: AppLocalizations.of(context).images,
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;
    setState(() => _imagePath = file.path);
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (
      name: name,
      description: _descController.text.trim(),
      imagePath: _imagePath,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.newPlaylist),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.playlistName,
                hintText: l10n.playlistNameHint,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              maxLines: 3,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: l10n.descriptionOptional,
                hintText: l10n.descriptionHint,
              ),
            ),
            const SizedBox(height: 4),
            // Portada: preview + selector de archivo
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: _imagePath != null
                        ? Image.file(
                            File(_imagePath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _placeholder(theme),
                          )
                        : _placeholder(theme),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _imagePath == null ? l10n.noCover : p.basename(_imagePath!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickImage,
                  icon: Icon(
                    _imagePath == null
                        ? Icons.image_outlined
                        : Icons.swap_horiz,
                    size: 18,
                  ),
                  label: Text(
                    _imagePath == null ? l10n.chooseImage : l10n.changeImage,
                  ),
                ),
                if (_imagePath != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: l10n.removeImage,
                    onPressed: () => setState(() => _imagePath = null),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.create)),
      ],
    );
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
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
        size: 20,
        color: theme.colorScheme.primary.withValues(alpha: 0.5),
      ),
    );
  }
}
