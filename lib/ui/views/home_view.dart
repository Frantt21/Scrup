import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../playback.dart';

/// Pantalla de inicio: barra de búsqueda en la parte superior y las
/// reproducciones recientes en un grid 1:1 con el artwork completo.
class HomeView extends StatefulWidget {
  /// Se llama al enviar una búsqueda desde el inicio (AppShell cambia a la
  /// pestaña Buscar y le pasa la consulta).
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

    return CustomScrollView(
      slivers: [
        // Cabecera: título + barra de búsqueda
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inicio',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Busca, reproduce y descubre',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  onSubmitted: _submitSearch,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Buscar canciones en YouTube…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Recientes',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Grid 1:1 de recientes
        if (!_loaded)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_recent.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyRecent(theme: theme),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
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
              }, childCount: _recent.length),
            ),
          ),
      ],
    );
  }
}

/// Tarjeta cuadrada con el artwork completo y título/artista en la esquina
/// inferior, con un hover que muestra el botón de play.
class _RecentCard extends StatefulWidget {
  final Track track;
  final VoidCallback onPlay;

  const _RecentCard({required this.track, required this.onPlay});

  @override
  State<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends State<_RecentCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = widget.track;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 150),
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

class _EmptyRecent extends StatelessWidget {
  final ThemeData theme;
  const _EmptyRecent({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Aún no has reproducido nada',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Usa la búsqueda de arriba para empezar',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
