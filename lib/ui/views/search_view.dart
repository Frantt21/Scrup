import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../services/ytdlp_service.dart';
import '../playback.dart';
import '../widgets/track_tile.dart';

/// Vista de búsqueda: busca canciones en YouTube y permite reproducirlas
/// o añadirlas a una playlist.
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  List<Track> _results = const [];
  bool _searching = false;
  String? _error;
  bool _hasSearched = false;
  final List<String> _recentSearches = ['Daft Punk', 'Lo-fi', 'Radiohead'];

  /// Contador para descartar respuestas de búsquedas obsoletas.
  int _searchToken = 0;

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _error = null;
      _hasSearched = true;
    });
    try {
      final tracks = await context.read<YtDlpService>().search(q);
      if (!mounted || token != _searchToken) return; // búsqueda obsoleta
      setState(() => _results = tracks);
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = const [];
        _error = e.toString();
      });
    } finally {
      if (mounted && token == _searchToken) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _addToPlaylist(BuildContext context, Track track) async {
    final messenger = ScaffoldMessenger.of(context);
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
              child: Text('Añadir a playlist',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'No tienes playlists todavía. Crea una nueva.',
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
              title: const Text('Nueva playlist'),
              onTap: () => _createAndSelect(ctx, db, track),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await db.addToPlaylist(selected, track);
    messenger.showSnackBar(
      const SnackBar(content: Text('Añadida a la playlist')),
    );
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
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nombre de la playlist',
          ),
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
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Buscar',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onSubmitted: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Buscar canciones en YouTube…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _recentSearches.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final q = _recentSearches[i];
                    return ActionChip(
                      label: Text(q),
                      onPressed: () {
                        _searchController.text = q;
                        _search(q);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note,
              size: 72,
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'Busca una canción para empezar a reproducirla',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty && !_searching) {
      return Center(
        child: Text(
          'Sin resultados. Prueba otra búsqueda.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final track = _results[i];
        return TrackTile(
          track: track,
          onPlay: () => playTrack(context, track),
          onAddToPlaylist: () => _addToPlaylist(context, track),
        );
      },
    );
  }
}
