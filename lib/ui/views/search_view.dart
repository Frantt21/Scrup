import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import '../../services/search_history_store.dart';
import '../../services/search_service.dart';
import 'artist_detail_view.dart';
import '../playback.dart';
import '../playlist_actions.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance, kPlayerOverlayInset;
import '../widgets/track_tile.dart';

/// Search view: searches songs on YouTube and lets you play them or add them to a playlist.
class SearchView extends StatefulWidget {
  /// External search query (launched from home). When it changes, the view runs the search and shows it. It is a [ValueNotifier] because the view consumes it (resets to null) to allow repeating an identical query.
  final ValueNotifier<String?>? searchRequest;

  /// Focus signal: when notified, the view focuses the search field (used when arriving at search from the header button).
  final ValueNotifier<int>? focusRequest;

  /// Return to home (no sidebar anymore).
  final VoidCallback? onBack;

  /// Open an artist detail. On mobile it is provided by AppShell: the screen is mounted INSIDE the shell (nav + miniplayer stay visible). If null (desktop), it is pushed as a full-screen route.
  final ValueChanged<YtmArtist>? onOpenArtist;

  const SearchView({
    super.key,
    this.searchRequest,
    this.focusRequest,
    this.onBack,
    this.onOpenArtist,
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

  /// Avatares reales de canal (UC… → URL), resueltos en background por [_resolveArtistAvatars] tras pintar la lista. Mientras no llega, la fila muestra el placeholder genérico (nunca la portada de una canción, que era el "avatar random" de antes).
  final Map<String, String?> _artistAvatars = {};
  bool _searching = false;
  String? _error;
  bool _hasSearched = false;

  /// Historial persistente de búsquedas: chips bajo el campo; un toque repite la consulta. Cada búsqueda exitosa sube al frente.
  List<String> _history = const [];

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
    // Historial persistente: se muestra como chips en ambas plataformas.
    unawaited(
      context.read<SearchHistoryStore>().load().then((h) {
        if (mounted) setState(() => _history = h);
      }),
    );
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
      // Historial: consulta exitosa al frente (persistente, dedupe).
      unawaited(
        context.read<SearchHistoryStore>().add(q).then((h) {
          if (mounted) setState(() => _history = h);
        }),
      );
      // Avatares en segundo plano: las canciones ya están en pantalla, la
      // cara del canal aparece cuando su request termina (UI no bloqueada).
      unawaited(_resolveArtistAvatars(artistList, token));
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

  /// Avatares (disco, instantáneo) + revalidación en background: cuando un canal cambia su avatar, [onUpdated] repinta esa fila.
  Future<void> _resolveArtistAvatars(
    List<YtmArtist> artists,
    int token,
  ) async {
    final map = await context.read<SearchService>().resolveArtistAvatars(
      artists,
      onUpdated: (browseId, url) {
        if (!mounted || token != _searchToken) return;
        setState(() => _artistAvatars[browseId] = url);
      },
    );
    if (!mounted || token != _searchToken) return;
    setState(() => _artistAvatars.addAll(map));
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

    // Móvil: todo el espacio (sin cristal flotante ni clearance del player); desktop: cristal flotante con clearance.
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
                    // Historial persistente de búsquedas: chips bajo el campo; un toque repite la consulta.
                  if (_history.isNotEmpty)
                    ...[for (final q in _history)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: ActionChip(
                          avatar: const Icon(
                            Icons.history_rounded,
                            size: 18,
                          ),
                          label: Text(q),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          onPressed: () {
                            _searchController.text = q;
                            _search(q);
                          },
                        ),
                      )]
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
                              itemCount: _history.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (context, i) {
                                final q = _history[i];
                                return ActionChip(
                                  label: Text(q),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
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
      // MISMO ancho útil que las demás listas (playlist/top tracks): esas
      // listas no llevan padding horizontal propio — el inset 8 lo pone el
      // TrackTile interno — así los bordes de todas las filas quedan
      // alineados entre screens.
      padding: const EdgeInsets.fromLTRB(8, 8, 8, kPlayerOverlayInset),
      itemCount: _results.length + _artists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        // Artistas PRIMERO (van con su propia fila).
        if (i < _artists.length) {
          final artist = _artists[i];
          return _ArtistTile(
            artist: artist,
            avatarUrl: _artistAvatars[artist.browseId],
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

  /// Toca un artista → screen de detalle. En móvil el AppShell lo monta
  /// DENTRO del shell (nav + miniplayer presentes); en desktop, push de
  /// ruta a pantalla completa.
  void _openArtist(YtmArtist artist) {
    final cb = widget.onOpenArtist;
    if (cb != null) {
      cb(artist);
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailView(artist: artist),
      ),
    );
  }
}

/// Artist row: rounded square (SAME look as the covers) with the channel's REAL avatar when it arrives, person placeholder while it is missing.
class _ArtistTile extends StatelessWidget {
  const _ArtistTile({
    required this.artist,
    required this.onTap,
    this.avatarUrl,
  });

  final YtmArtist artist;
  final VoidCallback onTap;

  /// Avatar resuelto en background (o null mientras/no disponible).
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final thumb = avatarUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            // CUADRADA redondeada (14dp), no círculo: mismo estilo que las
            // portadas de playlists/canciones, pero MÁS GRANDE que una fila
            // de canción (64dp) para destacar la sección de artistas.
            // Hi-res: el avatar base llega a ~176px; pedirlo a w1200 lo
            // deja nítido en cualquier DPR.
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 64,
                height: 64,
                child: thumb != null && thumb.isNotEmpty
                    ? CoverImage(
                        source: Track.hiResThumbnail(thumb) ?? thumb,
                        width: 64,
                        height: 64,
                        cacheWidth: 260,
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
