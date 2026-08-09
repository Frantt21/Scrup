import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/ytdlp_service.dart';
import '../playback.dart';
import '../playlist_actions.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;
import '../widgets/track_tile.dart';

/// Vista de búsqueda: busca canciones en YouTube y permite reproducirlas
/// o añadirlas a una playlist.
class SearchView extends StatefulWidget {
  /// Consulta de búsqueda externa (lanzada desde el inicio). Al cambiar, la
  /// vista ejecuta la búsqueda y la muestra. Es un [ValueNotifier] porque la
  /// vista lo consume (resetea a null) para permitir repetir una consulta
  /// idéntica.
  final ValueNotifier<String?>? searchRequest;

  /// Vuelve al inicio (ya no hay barra lateral).
  final VoidCallback? onBack;

  const SearchView({super.key, this.searchRequest, this.onBack});

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

  @override
  void initState() {
    super.initState();
    // Búsqueda lanzada desde la pantalla de inicio
    widget.searchRequest?.addListener(_onExternalSearch);
  }

  void _onExternalSearch() {
    final q = widget.searchRequest?.value;
    if (q == null || q.trim().isEmpty) return;
    // Consumir la consulta (reset a null) para que una búsqueda idéntica
    // repetida desde el inicio vuelva a notificar.
    widget.searchRequest?.value = null;
    _searchController.text = q;
    _search(q);
  }

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

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_onExternalSearch);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: l10n.backToHome,
                    onPressed: widget.onBack,
                  ),
                  Text(
                    l10n.searchTitle,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
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
                  hintText: l10n.searchHint,
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
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
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
              l10n.searchStartHint,
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
          l10n.searchNoResults,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      // El player flotante cubre la parte inferior: dejar espacio para que
      // los últimos resultados queden accesibles.
      padding: const EdgeInsets.fromLTRB(16, 8, 16, kPlayerOverlayInset),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final track = _results[i];
        return TrackTile(
          track: track,
          onPlay: () => playTrack(context, track),
          onAddToPlaylist: () => showAddToPlaylistSheet(context, track),
        );
      },
    );
  }
}
