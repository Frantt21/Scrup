import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../services/player_service.dart';
import '../../services/ytdlp_service.dart';
import 'widgets/player_bar.dart';
import 'widgets/track_tile.dart';

/// Pantalla principal: búsqueda de canciones + lista de resultados.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  List<Track> _results = const [];
  bool _searching = false;
  String? _error;
  bool _showEmptyState = true;
  final List<String> _recentSearches = ['Daft Punk', 'Lo-fi', 'Radiohead'];

  /// Contador para descartar respuestas de búsquedas obsoletas.
  int _searchToken = 0;

  @override
  void initState() {
    super.initState();
    // Errores de reproducción (URL expirada, 403, etc.)
    context.read<PlayerService>().errors.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error de reproducción: $message')),
      );
    });
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _error = null;
      _showEmptyState = false;
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

  Future<void> _play(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    final player = context.read<PlayerService>();
    final ytdlp = context.read<YtDlpService>();
    final db = context.read<AppDatabase>();
    try {
      final url = await ytdlp.getAudioUrl(track.id, title: track.title);
      final played = await player.playUrl(url, track);
      // Cache de metadatos para la próxima vez (solo si sigue vigente)
      if (played) await db.recordPlay(track);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('No se pudo reproducir: $e')),
      );
    }
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

    return Scaffold(
      body: Column(
        children: [
          // Encabezado con búsqueda
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Scrup',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 8),
                  // Chips de búsquedas recientes
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
          ),
          // Cuerpo
          Expanded(child: _buildBody(theme)),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
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

    if (_showEmptyState) {
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
          onPlay: () => _play(track),
        );
      },
    );
  }
}
