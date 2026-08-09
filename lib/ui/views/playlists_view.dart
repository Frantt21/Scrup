import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import 'playlist_detail_view.dart';

/// Vista de playlists: lista las playlists del usuario con opción de crear
/// nuevas y eliminar existentes.
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({super.key});

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  late final Stream<List<Playlist>> _playlistsStream;
  StreamSubscription<List<Playlist>>? _sub;
  List<Playlist> _playlists = const [];

  @override
  void initState() {
    super.initState();
    _playlistsStream = context.read<AppDatabase>().watchPlaylists();
    _sub = _playlistsStream.listen((playlists) {
      if (!mounted) return;
      setState(() => _playlists = playlists);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
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
    if (name != null && name.isNotEmpty) {
      await db.createPlaylist(name);
      messenger.showSnackBar(
        SnackBar(content: Text('Playlist "$name" creada')),
      );
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
    if (confirmed == true) {
      await db.deletePlaylist(playlist.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Playlist eliminada')),
      );
    }
  }

  void _openPlaylist(Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailView(playlist: playlist),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Playlists',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_playlists.length} guardadas',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _createPlaylist,
                icon: const Icon(Icons.add),
                label: const Text('Nueva'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? _EmptyPlaylists(theme: theme, onCreate: _createPlaylist)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _playlists.length,
                  itemBuilder: (context, i) {
                    final playlist = _playlists[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer,
                          child: Icon(
                            Icons.queue_music,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(playlist.name),
                        subtitle: Text(_dateLabel(playlist.createdAt)),
                        onTap: () => _openPlaylist(playlist),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Eliminar',
                          onPressed: () => _deletePlaylist(playlist),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _dateLabel(DateTime d) {
    final local = d.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }
}

class _EmptyPlaylists extends StatelessWidget {
  final ThemeData theme;
  final VoidCallback onCreate;

  const _EmptyPlaylists({required this.theme, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.queue_music,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'No tienes playlists todavía',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Crear la primera'),
          ),
        ],
      ),
    );
  }
}
