import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart';
import 'artist_detail_view.dart';
import '../playback.dart';
import '../playlist_actions.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance, kPlayerOverlayInset;
import '../widgets/track_tile.dart';

/// Vista de búsqueda: busca canciones en YouTube y permite reproducirlas
/// o añadirlas a una playlist.
class SearchView extends StatefulWidget {
  /// Consulta de búsqueda externa (lanzada desde el inicio). Al cambiar, la
  /// vista ejecuta la búsqueda y la muestra. Es un [ValueNotifier] porque la
  /// vista lo consume (resetea a null) para permitir repetir una consulta
  /// idéntica.
  final ValueNotifier<String?>? searchRequest;

  /// Señal de foco: al notificarse, la vista enfoca el campo de búsqueda
  /// (se usa cuando se llega a la búsqueda desde el botón del header).
  final ValueNotifier<int>? focusRequest;

  /// Vuelve al inicio (ya no hay barra lateral).
  final VoidCallback? onBack;

  const SearchView({
    super.key,
    this.searchRequest,
    this.focusRequest,
    this.onBack,
  });

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _searchFocus = FocusNode();

  List<Track> _results = const [];
  List<YtmArtist> _artists = const [];
  bool _searching = false;
  String? _error;
  bool _hasSearched = false;
  final List<String> _recentSearches = ['Daft Punk', 'Lo-fi', 'Radiohead'];

  /// Pista en reproducción (para el indicador de "en reproducción").
  Track? _currentTrack;
  bool _playing = false;
  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _nullTrackTimer;

  /// Contador para descartar respuestas de búsquedas obsoletas.
  int _searchToken = 0;

  @override
  void initState() {
    super.initState();
    // Búsqueda lanzada desde la pantalla de inicio
    widget.searchRequest?.addListener(_onExternalSearch);
    widget.focusRequest?.addListener(_onFocusRequest);
    // Indicador de "en reproducción" en las filas de resultados
    final player = context.read<PlayerService>();
    _currentTrack = player.currentTrackValue;
    _playing = player.isPlaying;
    _trackSub = player.currentTrack.listen((t) {
      if (!mounted) return;
      if (t == null) {
        _nullTrackTimer?.cancel();
        _nullTrackTimer = Timer(const Duration(milliseconds: 80), () {
          if (mounted) setState(() => _currentTrack = null);
        });
        return;
      }
      _nullTrackTimer?.cancel();
      setState(() => _currentTrack = t);
    });
    _playingSub = player.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
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

  /// Enfoca el campo de búsqueda (al llegar desde el botón del header).
  void _onFocusRequest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
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
      _hasSearched = true;
    });
    try {
      // Una sola request: InnerTube (filtro de canciones). Los artistas se
      // DERIVAN de los resultados (cada fila trae el canal de su artista):
      // sin la request extra de la búsqueda general, la búsqueda vuelve a
      // su velocidad anterior (~0.3-1s en frío, instantánea con caché).
      final tracks = await context.read<SearchService>().search(q);
      if (!mounted || token != _searchToken) return; // búsqueda obsoleta
      final artistList = SearchService.deriveArtists(tracks, limit: 8);
      setState(() {
        _results = tracks;
        _artists = artistList;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = const [];
        _artists = const [];
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
    widget.focusRequest?.removeListener(_onFocusRequest);
    _trackSub?.cancel();
    _playingSub?.cancel();
    _nullTrackTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final bool mobile = Binaries.isMobile;

    // En móvil usamos todo el espacio (sin contenedor flotante ni clearance
    // del player); en desktop el cristal flotante con clearance.
    final Widget body = mobile
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // Misma alineación de header que Library en móvil (16px).
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Móvil: header sin botón (la navegación vive en la
                    // NavigationBar inferior). El título va en una caja de la
                    // MISMA altura que las filas con botón de Inicio/Librería
                    // (48dp, centrada): así los glifos quedan a la misma
                    // altura visual que esos títulos.
                    SizedBox(
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.searchTitle,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onSubmitted: _search,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: l10n.searchHint,
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(theme)),
            ],
          )
        : Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, kPlayerClearance),
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.72,
                  ),
                ),
                child: Column(
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
                                icon: const Icon(Icons.arrow_back_rounded),
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
                            focusNode: _searchFocus,
                            onSubmitted: _search,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: l10n.searchHint,
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _searching
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : null,
                              filled: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 34,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _recentSearches.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
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
                ),
              ),
            ),
          );

    return body;
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
                Icons.error_rounded,
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
              Icons.music_note_rounded,
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, kPlayerOverlayInset),
      itemCount: _results.length + _artists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        // Artistas PRIMERO (van con su propia fila).
        if (i < _artists.length) {
          final artist = _artists[i];
          return _ArtistTile(
            artist: artist,
            onTap: () => _openArtist(artist),
          );
        }
        final track = _results[i - _artists.length];
        return TrackTile(
          track: track,
          onPlay: () => playTrack(context, track),
          onAddToPlaylist: () => showAddToPlaylistDialog(context, track),
          isCurrent: track.id == _currentTrack?.id,
          isPlaying: _playing,
        );
      },
    );
  }

  /// Toca un artista → screen de detalle (push a pantalla completa). El
  /// detalle carga sus datos por sí mismo (cache 24h por canal).
  void _openArtist(YtmArtist artist) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailView(artist: artist),
      ),
    );
  }
}

/// Fila de artista: avatar circular + nombre. Toque → play del catálogo.
class _ArtistTile extends StatelessWidget {
  const _ArtistTile({required this.artist, required this.onTap});

  final YtmArtist artist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final thumb = artist.thumbnailUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 44,
                height: 44,
                child: thumb != null && thumb.isNotEmpty
                    ? CoverImage(
                        source: thumb,
                        width: 44,
                        height: 44,
                        cacheWidth: 96,
                        fit: BoxFit.cover,
                        fallback: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.person_rounded,
                            size: 24,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person_rounded,
                          size: 24,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    l10n.searchArtistsSection,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.play_arrow_rounded,
              size: 24,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
