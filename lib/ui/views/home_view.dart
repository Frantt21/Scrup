import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../playback.dart';
import '../playlist_actions.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;

/// Pantalla de inicio: barra de búsqueda arriba y las reproducciones
/// recientes en un grid 1:1 de SOLO DOS FILAS (las columnas se acomodan al
/// ancho de la ventana; las demás recientes no se muestran). Las playlists
/// viven en el contenedor lateral.
class HomeView extends StatefulWidget {
  /// Se llama al enviar una búsqueda desde el inicio (AppShell cambia a la
  /// vista Buscar y le pasa la consulta).
  final ValueChanged<String>? onSearch;

  const HomeView({super.key, this.onSearch});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  late final Stream<List<Track>> _recentStream;
  StreamSubscription<List<Track>>? _sub;
  List<Track> _recent = const [];
  bool _loaded = false;

  /// Tamaño fijo de las tarjetas (~200px); las columnas se deducen del ancho.
  static const _cardExtent = 200.0;
  static const _rows = 2;

  @override
  void initState() {
    super.initState();
    _recentStream = context.read<AppDatabase>().watchRecentlyPlayed(limit: 30);
    _sub = _recentStream.listen((tracks) {
      if (!mounted) return;
      setState(() {
        _recent = tracks;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _submitSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    widget.onSearch?.call(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Columnas que caben en el ancho disponible (tarjetas de ~200px).
        final cols = ((constraints.maxWidth - 32) / (_cardExtent + 12))
            .floor()
            .clamp(1, 10);
        final visible = _recent.length.clamp(0, cols * _rows);

        return CustomScrollView(
          slivers: [
            // Barra de búsqueda (sin título ni subtítulo)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: TextField(
                  onSubmitted: _submitSearch,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l10n.searchHint,
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            if (!_loaded)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            if (_loaded)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                  child: _recent.isEmpty
                      ? _EmptyHint(theme: theme)
                      : Text(
                          l10n.recentTitle,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            if (_loaded && _recent.isNotEmpty)
              SliverPadding(
                // El player flotante cubre la parte inferior: dejar espacio
                // para que la última fila del grid quede accesible.
                padding: const EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  kPlayerOverlayInset,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final track = _recent[i];
                    return _RecentCard(
                      track: track,
                      onPlay: () => playTrack(context, track),
                    );
                  }, childCount: visible),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Tarjeta cuadrada con el artwork completo y título/artista en la esquina
/// inferior, con un hover que muestra el botón de play (sin animación de
/// escala).
class _RecentCard extends StatefulWidget {
  final Track track;
  final VoidCallback onPlay;

  const _RecentCard({required this.track, required this.onPlay});

  @override
  State<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends State<_RecentCard> {
  bool _hovered = false;

  /// Menú contextual (clic derecho) sobre la tarjeta: añadir a playlist.
  Future<void> _showMenu(Offset position) async {
    final l10n = AppLocalizations.of(context);
    final action = await showMenu<String>(
      context: context,
      // Anclaje correcto: recta de tamaño cero en la posición del cursor.
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        ContextMenuItem(
          value: 'add',
          icon: Icons.playlist_add,
          label: l10n.addToPlaylist,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await showAddToPlaylistSheet(context, widget.track);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = widget.track;

    return GestureDetector(
      onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hovered
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : Colors.transparent,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              onTap: widget.onPlay,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Artwork completo
                  _artwork(theme),
                  // Gradiente inferior para legibilidad del texto
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                        stops: [0.5, 1.0],
                      ),
                    ),
                  ),
                  // Título + artista en la esquina inferior
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Play al hacer hover
                  if (_hovered)
                    Center(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 36,
                          color: theme.colorScheme.primary,
                        ),
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

  Widget _artwork(ThemeData theme) {
    final url = widget.track.thumbnailUrl;
    if (url == null) {
      return Container(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Icon(
          Icons.music_note,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      // Decodificar a un tamaño moderado: el grid muestra miniaturas de
      // ~200px, no hace falta la resolución completa.
      cacheWidth: 500,
      errorBuilder: (_, _, _) => Container(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Icon(
          Icons.music_note,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Aviso compacto cuando no hay reproducciones recientes.
class _EmptyHint extends StatelessWidget {
  final ThemeData theme;

  const _EmptyHint({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.history,
          size: 40,
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 8),
        Text(
          AppLocalizations.of(context).recentEmptyTitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          AppLocalizations.of(context).recentEmptyHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
