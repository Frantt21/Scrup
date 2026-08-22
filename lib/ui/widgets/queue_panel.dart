import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/player_service.dart';
import 'track_tile.dart';

/// Ancho fijo del panel de cola abierto (igual filosofía que el sidebar).
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
      // Al cerrar el `end` es 0: el TweenAnimationBuilder anima desde el
      // valor ACTUAL hasta el nuevo `end` (anima el colapso hacia la
      // derecha, no un salto). Al abrir, de 0 al ancho fijo.
      tween: Tween(begin: 0, end: open ? kQueuePanelWidth : 0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, width, child) {
        // Solo margen DERECHO, espejo exacto del sidebar (que usa margen
        // izquierdo 12): el hueco entre el contenido y el panel lo define
        // cada vista con su padding interno (como en el lado del sidebar),
        // así los espaciados quedan uniformes y simétricos. El margen
        // derecho acompaña la animación de forma proporcional (12 abierto,
        // 0 al colapsar) para que el panel se deslice sin dejar columna
        // invisible entre el contenido y el borde.
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

/// Contenido del panel: cristal + cabecera + lista de la cola.
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
    // SOLO estos notifiers reconstruyen el panel: los ticks de posición no
    // los tocan, así que la lista no se reconstruye con cada segundo (la
    // duración/posición del player viven en streams que el panel no mira).
    // `shuffle` se incluye para que el botón de la cabecera refleje (y
    // cambie) el modo aleatorio sin reconstruir la lista.
    final queueListenable = Listenable.merge([
      player.queue,
      player.queueIndex,
      player.shuffle,
    ]);

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
            // Plano: un único tono oscuro, sin degradado, para UI neutra y
            // coherente.
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.72,
            ),
          ),
          child: StreamBuilder<bool>(
            // El indicador "en reproducción" sigue el stream de play/pausa
            // (no la posición). `initialData` evita un parpadeo al abrir.
            stream: player.playing,
            initialData: player.isPlaying,
            builder: (context, playingSnap) {
              final playing = playingSnap.data ?? false;
              return AnimatedBuilder(
                animation: queueListenable,
                builder: (context, _) {
                  final queue = player.queue.value;
                  final index = player.queueIndex.value;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Cabecera: título + nº de canciones
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.queue_music,
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
                            // Shuffle: refleja el modo aleatorio con el que
                            // el sistema elige la siguiente canción (lila
                            // cuando está activo) y permite alternarlo sin
                            // salir de la cola.
                            IconButton(
                              icon: Icon(
                                Icons.shuffle,
                                size: 17,
                                color: player.shuffle.value
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              padding: EdgeInsets.zero,
                              tooltip: player.shuffle.value
                                  ? l10n.shuffleOn
                                  : l10n.shuffle,
                              onPressed: player.toggleShuffle,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: queue.isEmpty
                            ? _EmptyQueue(theme: theme, l10n: l10n)
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  0,
                                  10,
                                  12,
                                ),
                                itemCount: queue.length,
                                itemBuilder: (context, i) {
                                  final track = queue[i];
                                  // El índice ES la identidad dentro de la
                                  // cola (cada pista aparece una sola vez).
                                  final isCurrent = i == index;
                                  // Sin `trailing`: TrackTile ya dibuja su
                                  // propio ecualizador (NowPlayingBars) junto
                                  // a la duración cuando es la pista actual;
                                  // añadir otro aquí lo duplicaba.
                                  return TrackTile(
                                    track: track,
                                    isCurrent: isCurrent,
                                    isPlaying: playing && isCurrent,
                                    onPlay: () => player.playQueueAt(i),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
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
              Icons.queue_music,
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
