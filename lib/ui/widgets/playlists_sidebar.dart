import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../theme_controller.dart';
import 'scrup_snackbar.dart';

/// Ancho fijo del contenedor lateral de playlists.
const double kSidebarWidth = 250;

/// Contenedor lateral flotante tipo glass: ocupa su propio espacio a la
/// izquierda (no se superpone al contenido) y muestra TODAS las playlists en
/// una lista vertical. Al final de la lista hay un item que emula una
/// playlist pero es un botón para crear una nueva.
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

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _countsSub?.cancel();
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final messenger = ScaffoldMessenger.of(context);
    final db = context.read<AppDatabase>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nombre'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Crear'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final id = await db.createPlaylist(name);
    showScrupSnackBar(messenger, 'Playlist "$name" creada');
    // Abrir la recién creada directamente.
    if (!mounted) return;
    final playlist = await db.getPlaylist(id);
    if (mounted && playlist != null) {
      widget.onSelectPlaylist(playlist);
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final messenger = ScaffoldMessenger.of(context);
    final db = context.read<AppDatabase>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar playlist'),
        content: Text('¿Eliminar "${playlist.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await db.deletePlaylist(playlist.id);
    // Si se eliminó la playlist abierta, cerrar el detalle.
    if (widget.openPlaylistId == playlist.id) {
      widget.onSelectPlaylist(null);
    }
    if (!mounted) return;
    showScrupSnackBar(messenger, 'Playlist eliminada');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeController = context.watch<ThemeController>();
    final base = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.55,
    );

    return Container(
      width: kSidebarWidth,
      margin: const EdgeInsets.fromLTRB(12, 12, 8, 12),
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
              // Translúcido + tinte sutil del artwork, como el player
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  themeController.accentColor?.withValues(alpha: 0.20) ?? base,
                  base,
                ],
              ),
            ),
            child: Material(
              // Transparente para que los ripples se dibujen sobre el cristal
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: Text(
                      'Playlists',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
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
                          ),
                        const SizedBox(height: 4),
                        _CreatePlaylistTile(onTap: _createPlaylist),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
            'Aún no tienes playlists',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Crea una desde aquí',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila de playlist: miniatura + nombre + nº de canciones, con borrado al
/// hacer hover. La abierta se resalta con el tinte del color primario.
class _PlaylistRow extends StatefulWidget {
  final Playlist playlist;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PlaylistRow({
    required this.playlist,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDelete,
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
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        '${widget.count} '
                        '${widget.count == 1 ? 'canción' : 'canciones'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Espacio reservado para el borrar: evita que el nombre
                // "salte" de ancho cuando aparece el botón en hover.
                SizedBox(
                  width: 32,
                  child: _hovered
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Eliminar',
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
    final url = widget.playlist.coverUrl;
    if (url == null) {
      return Container(
        width: 40,
        height: 40,
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
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: 120,
          errorBuilder: (_, _, _) => Container(
            color: theme.colorScheme.surfaceContainerHigh,
            child: Icon(
              Icons.queue_music,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Item final que emula una playlist pero es un botón para crear una nueva.
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
                  'Nueva playlist',
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
