import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import 'track_tile.dart';

/// Ancho fijo del panel de cola abierto (misma filosofía que el sidebar).
const double kQueuePanelWidth = 300;

/// Margen vertical del panel (el mismo 12 que usan sidebar y player).
const double _kQueueMargin = 12;

/// Panel de la COLA de reproducción: contenedor flotante tipo glass (misma
/// receta que el sidebar: blur, degradado oscuro translúcido y sombra) que
/// se DESLIZA desde el borde derecho empujando el contenedor principal
/// (el contenido y el player se corren a la izquierda; al cerrarlo vuelven).
class QueuePanel extends StatelessWidget {
  /// `true` = cola visible (el panel ocupa su ancho); `false` = colapsado.
  final bool open;

  const QueuePanel({super.key, required this.open});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final player = context.read<PlayerService>();

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: open ? kQueuePanelWidth : 0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, width, child) {
        final right = width / kQueuePanelWidth * _kQueueMargin;
        return Container(
          width: width,
          margin: EdgeInsets.fromLTRB(0, _kQueueMargin, right, _kQueueMargin),
          child: ClipRect(child: child),
        );
      },
      child: _QueueGlass(player: player, theme: theme, l10n: l10n),
    );
  }
}

/// Contenedor arrastrable de la cola en Android (NO es un screen): se muestra
/// como bottom sheet con asa, se puede deslizar hacia abajo para cerrarlo.
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final player = context.read<PlayerService>();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Asa de arrastre.
              const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 4),
                child: SizedBox(
                  width: 36,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x66FFFFFF),
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: _QueueBody(player: player, theme: theme, l10n: l10n),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Contenido del panel de la cola (desktop) con su cristal.
class _QueueGlass extends StatelessWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;

  const _QueueGlass({
    required this.player,
    required this.theme,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            borderRadius: BorderRadius.circular(18),
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.72,
            ),
          ),
          child: _QueueBody(player: player, theme: theme, l10n: l10n),
        ),
      ),
    );
  }
}

/// Lista de la cola (con su cabecera y el recuento). Compartida entre el
/// panel flotante (desktop) y el overlay a pantalla completa (móvil).
class _QueueBody extends StatelessWidget {
  final PlayerService player;
  final ThemeData theme;
  final AppLocalizations l10n;

  const _QueueBody({
    required this.player,
    required this.theme,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final queueListenable = Listenable.merge([
      player.queue,
      player.queueIndex,
      player.shuffle,
    ]);

    return StreamBuilder<bool>(
      stream: player.playing,
      initialData: player.isPlaying,
      builder: (context, playingSnap) {
        final playing = playingSnap.data ?? false;
        return AnimatedBuilder(
          animation: queueListenable,
          builder: (context, _) {
            final queue = player.queue.value;
            final index = player.queueIndex.value;
            return Material(
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cabecera: título + nº de canciones
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      children: [
                              Icon(
                                Icons.queue_music_rounded,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.queueTitle,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                l10n.songCount(queue.length),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: queue.isEmpty
                              ? _EmptyQueue(theme: theme, l10n: l10n)
                              : ReorderableListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    0,
                                    10,
                                    12,
                                  ),
                                  buildDefaultDragHandles: false,
                                  proxyDecorator:
                                      (child, index, animation) =>
                                          AnimatedBuilder(
                                            animation: animation,
                                            builder: (_, child) =>
                                                Transform.scale(
                                                  scale:
                                                      1 +
                                                      animation.value * 0.02,
                                                  child: child,
                                                ),
                                            child: child,
                                          ),
                                  itemCount: queue.length,
                                  onReorderItem: (oldIndex, newIndex) {
                                    player.reorderQueue(oldIndex, newIndex);
                                  },
                                  itemBuilder: (context, i) {
                                    final track = queue[i];
                                    final isCurrent = i == index;
                                    return _QueueTrackRow(
                                      key: ValueKey('${track.id}_$i'),
                                      index: i,
                                      isCurrent: isCurrent,
                                      isPlaying: playing && isCurrent,
                                      track: track,
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
      );
  }
}

/// Estado vacío: aún no hay nada en la cola.
class _EmptyQueue extends StatelessWidget {
  final ThemeData theme;
  final AppLocalizations l10n;

  const _EmptyQueue({required this.theme, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 40,
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.queueEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.queueEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fila reordenable de la cola: mismo patrón que _SortableTrackRow del
/// playlist detail. Envuelve la TrackTile y añade un grip de arrastre con
/// ReorderableDragStartListener visible al hover.
class _QueueTrackRow extends StatefulWidget {
  final int index;
  final Track track;
  final bool isCurrent;
  final bool isPlaying;

  const _QueueTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
  });

  @override
  State<_QueueTrackRow> createState() => _QueueTrackRowState();
}

class _QueueTrackRowState extends State<_QueueTrackRow> {
  bool _hovered = false;

  /// Acento del artwork de esta pista, resuelto en initState (caché síncrona)
  /// o tras extraer el trío (async). `null` = la fila usa los colores del tema.
  Color? _accent;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveAccent());
  }

  Future<void> _resolveAccent() async {
    final url = widget.track.thumbnailUrl;
    if (url == null || url.isEmpty) return;
    final store = context.read<PaletteCacheStore>();
    final cached = store.get(url);
    if (cached != null) {
      _accent = cached;
      return;
    }
    if (store.isFailed(url)) return;
    try {
      final artworkCache = context.read<ArtworkCacheService>();
      final trio = await ArtworkPaletteService.trioFor(
        url,
        store,
        artworkCache: artworkCache,
      );
      final accent =
          trio.isEmpty
              ? null
              : (ArtworkPaletteService.accentFromTrio(trio) ?? trio.first);
      if (accent != null && mounted) {
        setState(() => _accent = accent);
      }
    } catch (_) {
      // Sin acento: la fila se queda con los colores estándar del tema.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final accent = _accent;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: TrackTile(
                track: widget.track,
                isCurrent: widget.isCurrent,
                isPlaying: widget.isPlaying,
                onPlay: () => player.playQueueAt(widget.index),
                showDuration: false,
                accentColor: accent,
              ),
            ),
            ReorderableDragStartListener(
              index: widget.index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color:
                      (_hovered ? (accent ?? theme.colorScheme.primary) : theme
                              .colorScheme
                              .outlineVariant)
                          .withValues(alpha: _hovered ? 0.85 : 0.45),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
