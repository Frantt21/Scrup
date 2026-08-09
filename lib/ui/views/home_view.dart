import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../playback.dart';
import '../widgets/track_tile.dart';

/// Pantalla de inicio: muestra las reproducciones recientes (desde SQLite)
/// y un atajo para crear/reproducir playlists.
class HomeView extends StatefulWidget {
  const HomeView({super.key});

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CustomScrollView(
      slivers: [
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
                  'Tus reproducciones recientes',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Lista de recientes
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
            sliver: SliverList.separated(
              itemCount: _recent.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final track = _recent[i];
                return TrackTile(
                  track: track,
                  onPlay: () => playTrack(context, track),
                );
              },
            ),
          ),
      ],
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
            'Busca una canción para empezar',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
