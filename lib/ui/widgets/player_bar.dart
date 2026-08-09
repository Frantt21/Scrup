import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';

/// Espacio vertical que ocupa el player flotante en la parte inferior de la
/// ventana (barra + márgenes). Los scrollables de las vistas lo usan como
/// padding inferior para que sus últimos items queden accesibles por encima
/// del player.
const double kPlayerOverlayInset = 104;

/// Player flotante tipo glass: tarjeta translúcida con blur que flota sobre
/// el contenido. La barra de progreso (sin dot, con tiempos) queda entre la
/// información de la canción (izquierda) y el control de volumen (derecha),
/// con los controles de reproducción encima.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key});

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  Track? _track;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _buffering = false;

  /// Posición del slider durante el arrastre: mientras se arrastra NO se
  /// hace seek (el seek real ocurre al soltar), solo se muestra la posición
  /// del dedo en la UI (slider y tiempo).
  double? _dragValue;

  /// Id de la playlist de Favoritos (para el botón de corazón).
  int _favoritesId = -1;

  /// `true` mientras la pista actual esté en Favoritos (stream reactivo).
  bool _isFavorite = false;

  StreamSubscription<bool>? _favSub;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    final db = context.read<AppDatabase>();
    // Valores iniciales: si la sesión se restauró antes de que este widget
    // se construyera (los streams broadcast no re-emiten lo pasado), leer la
    // pista/duración actuales evita la pantalla "Sin reproducción".
    _track = player.currentTrackValue;
    _duration = player.durationValue;
    _subs.addAll([
      player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() {
          _track = t;
          _dragValue = null;
        });
        _refreshFavoriteState();
      }),
      player.position.listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
      }),
      player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      }),
      player.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      }),
      player.buffering.listen((b) {
        if (!mounted) return;
        setState(() => _buffering = b);
      }),
    ]);
    // Estado de favorito reactivo: observar la playlist de Favoritos.
    unawaited(_setupFavorites(db));
  }

  /// Resuelve el id de Favoritos y observa si la pista actual está dentro.
  Future<void> _setupFavorites(AppDatabase db) async {
    final id = await db.ensureFavoritesPlaylist();
    if (!mounted) return;
    _favoritesId = id;
    final track = _track;
    if (track == null) return;
    _favSub = db.watchTrackInPlaylist(id, track.id).listen((inside) {
      if (!mounted) return;
      setState(() => _isFavorite = inside);
    });
  }

  /// Re-suscribe la observación de Favoritos cuando cambia la pista. El
  /// corazón se resetea ANTES de re-suscribir para no mostrar el estado de la
  /// pista anterior durante un instante (parpadeo).
  void _refreshFavoriteState() {
    if (_favoritesId < 0) return;
    final track = _track;
    final db = context.read<AppDatabase>();
    _favSub?.cancel();
    if (!mounted) return;
    setState(() => _isFavorite = false);
    if (track == null) return;
    _favSub = db.watchTrackInPlaylist(_favoritesId, track.id).listen((inside) {
      if (!mounted) return;
      setState(() => _isFavorite = inside);
    });
  }

  /// Menú contextual (clic derecho) sobre el player: añadir la pista actual
  /// a una playlist.
  Future<void> _showContextMenu(Offset position) async {
    final track = _track;
    if (track == null) return;
    final action = await showMenu<String>(
      context: context,
      // Anclaje correcto: recta de tamaño cero en la posición del cursor.
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'add',
          child: Row(
            children: [
              Icon(Icons.playlist_add),
              SizedBox(width: 10),
              Text('Añadir a playlist'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await showAddToPlaylistSheet(context, track);
    }
  }

  /// Añade o quita la pista actual de la playlist de Favoritos.
  Future<void> _toggleFavorite() async {
    final track = _track;
    if (track == null) return;
    final db = context.read<AppDatabase>();
    if (_isFavorite) {
      await db.removeFromPlaylist(_favoritesId, track.id);
    } else {
      await db.addToPlaylist(_favoritesId, track);
    }
  }

  @override
  void dispose() {
    _favSub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Formatea una duración como `m:ss` (dígitos tabulares para que no baile).
  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = context.read<PlayerService>();
    final cache = context.read<AudioCacheService>();
    final themeController = context.watch<ThemeController>();
    final hasTrack = _track != null;
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // Durante el arrastre se muestra la posición del dedo; el seek real se
    // hace al soltar (onChangeEnd), no en cada tick.
    final shownProgress = _dragValue ?? progress;
    final shownPosition = _dragValue != null
        ? Duration(milliseconds: (_dragValue! * total.inMilliseconds).round())
        : _position;

    // Base translúcida del cristal (el blur se aplica detrás).
    final base = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.55,
    );

    return GestureDetector(
      onSecondaryTapUp: (details) => _showContextMenu(details.globalPosition),
      child: Container(
        // Sombra exterior (fuera del clip para que no se recorte)
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
          child: BackdropFilter(
            // Cristal: difumina el contenido que pasa por detrás
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                // Translúcido + tinte sutil del artwork, desvaneciéndose a la
                // derecha. Sin borde: el cristal se funde con el fondo.
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    themeController.accentColor?.withValues(alpha: 0.20) ??
                        base,
                    base,
                  ],
                ),
              ),
              child: Material(
                // Material transparente para que los ripples de los botones se
                // dibujen sobre el cristal
                color: Colors.transparent,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          // Izquierda: información de la canción
                          Expanded(
                            child: _buildTrackInfo(theme, cache, player),
                          ),
                          const SizedBox(width: 12),
                          // Centro: controles y, debajo, la barra de progreso
                          // (con tiempos), entre la info y el volumen.
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _buildControls(theme, player, hasTrack),
                                SizedBox(
                                  height: 22,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 38,
                                        child: Text(
                                          _fmt(
                                            hasTrack
                                                ? shownPosition
                                                : Duration.zero,
                                          ),
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                      ),
                                      Expanded(
                                        child: SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 3,
                                            // Sin dot: el pulgar es invisible;
                                            // se arrastra/toca la línea.
                                            thumbShape:
                                                const RoundSliderThumbShape(
                                                  enabledThumbRadius: 0,
                                                ),
                                            overlayShape:
                                                const RoundSliderOverlayShape(
                                                  overlayRadius: 0,
                                                ),
                                            showValueIndicator:
                                                ShowValueIndicator.never,
                                            activeTrackColor:
                                                theme.colorScheme.primary,
                                          ),
                                          child: Slider(
                                            value: shownProgress,
                                            onChanged: hasTrack
                                                ? (v) => setState(
                                                    () => _dragValue = v,
                                                  )
                                                : null,
                                            onChangeEnd: hasTrack
                                                ? (v) {
                                                    final target = Duration(
                                                      milliseconds:
                                                          (v * total.inMilliseconds)
                                                              .round(),
                                                    );
                                                    player.seek(target);
                                                    setState(
                                                      () => _dragValue = null,
                                                    );
                                                  }
                                                : null,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 38,
                                        child: Text(
                                          _fmt(total),
                                          textAlign: TextAlign.right,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Derecha: volumen
                          Expanded(child: _buildVolume(context, theme, player)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Izquierda: artwork + título (con estado de descarga) y artista.
  Widget _buildTrackInfo(
    ThemeData theme,
    AudioCacheService cache,
    PlayerService player,
  ) {
    if (_track == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Sin reproducción',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 36,
            height: 36,
            child: _track!.thumbnailUrl != null
                ? Image.network(
                    _track!.thumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _artworkFallback(theme),
                  )
                : _artworkFallback(theme),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double?>(
                valueListenable: cache.progress,
                builder: (context, downloadPct, _) {
                  return ValueListenableBuilder<String?>(
                    valueListenable: player.preparingTrackId,
                    builder: (context, preparingId, _) {
                      // Solo mostrar el % si la descarga es de la pista que
                      // se está preparando (si el usuario saltó de pista, la
                      // descarga sigue en segundo plano).
                      final downloadingCurrent =
                          cache.downloadingId.value == preparingId;
                      final String label;
                      if (downloadPct != null &&
                          downloadPct < 1 &&
                          downloadingCurrent) {
                        label = 'Descargando… ${(downloadPct * 100).round()}%';
                      } else if (preparingId != null) {
                        label = 'Preparando…';
                      } else {
                        label = _track!.title;
                      }
                      return Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      );
                    },
                  );
                },
              ),
              Text(
                _track!.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Centro: controles de reproducción. Todos los botones usan constraints
  /// explícitos idénticos (34x40) con el play en su propia caja fija, para
  /// que toda la fila quede perfectamente alineada verticalmente.
  Widget _buildControls(ThemeData theme, PlayerService player, bool hasTrack) {
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    const iconSize = 20.0;
    const btnConstraints = BoxConstraints.tightFor(width: 34, height: 40);

    return ValueListenableBuilder<String?>(
      valueListenable: player.preparingTrackId,
      builder: (context, preparingId, _) {
        final preparing = preparingId != null;

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Shuffle (mismo lenguaje visual que el play: relleno lila
            // cuando está activo)
            ValueListenableBuilder<bool>(
              valueListenable: player.shuffle,
              builder: (context, on, _) => IconButton(
                icon: Icon(
                  on ? Icons.shuffle_on : Icons.shuffle,
                  size: on ? 26 : iconSize,
                ),
                constraints: btnConstraints,
                padding: EdgeInsets.zero,
                color: on ? primary : muted,
                tooltip: on ? 'Aleatorio: activo' : 'Aleatorio',
                onPressed: player.toggleShuffle,
              ),
            ),
            // Anterior
            IconButton(
              icon: const Icon(Icons.skip_previous),
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: 'Anterior',
              onPressed: hasTrack ? player.previous : null,
            ),
            // Play / Pausa (o loader). Footprint fijo (44x40) para que la
            // barra no cambie de tamaño ni el botón se desalinee.
            SizedBox(
              width: 44,
              height: 40,
              child: Center(
                child: preparing || _buffering
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : IconButton(
                        iconSize: 36,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        icon: Icon(
                          _playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: primary,
                        ),
                        tooltip: _playing ? 'Pausar' : 'Reproducir',
                        onPressed: hasTrack ? player.togglePlayPause : null,
                      ),
              ),
            ),
            // Siguiente
            IconButton(
              icon: const Icon(Icons.skip_next),
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: 'Siguiente',
              onPressed: hasTrack ? player.next : null,
            ),
            // Repeat (cicla off → all → one)
            ValueListenableBuilder<LoopMode>(
              valueListenable: player.repeatMode,
              builder: (context, mode, _) {
                final active = mode != LoopMode.off;
                return IconButton(
                  icon: Icon(
                    mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                    size: iconSize,
                  ),
                  constraints: btnConstraints,
                  padding: EdgeInsets.zero,
                  color: active ? primary : muted,
                  tooltip: switch (mode) {
                    LoopMode.off => 'Repetir: desactivado',
                    LoopMode.all => 'Repetir: toda la cola',
                    LoopMode.one => 'Repetir: canción actual',
                  },
                  onPressed: player.toggleRepeat,
                );
              },
            ),
            // Radio (mismo artista al terminar)
            ValueListenableBuilder<bool>(
              valueListenable: player.radio,
              builder: (context, on, _) => IconButton(
                icon: Icon(
                  Icons.radio,
                  size: iconSize,
                  color: on ? primary : muted,
                ),
                constraints: btnConstraints,
                padding: EdgeInsets.zero,
                tooltip: on ? 'Radio: activa' : 'Radio: inactiva',
                onPressed: player.toggleRadio,
              ),
            ),
            // Favorito: añade/quita la pista actual de la playlist de
            // Favoritos. Corazón lleno en lila cuando está guardada.
            IconButton(
              icon: Icon(
                _isFavorite ? Icons.favorite : Icons.favorite_border,
                size: iconSize,
              ),
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
              color: _isFavorite ? primary : muted,
              tooltip: _isFavorite
                  ? 'Quitar de favoritos'
                  : 'Añadir a favoritos',
              onPressed: _track == null ? null : _toggleFavorite,
            ),
          ],
        );
      },
    );
  }

  Widget _artworkFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note,
        size: 22,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// Derecha: control de volumen compacto (icono con mute + slider corto).
  Widget _buildVolume(
    BuildContext context,
    ThemeData theme,
    PlayerService player,
  ) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return ValueListenableBuilder<double>(
      valueListenable: player.volume,
      builder: (context, vol, _) {
        final icon = vol <= 0
            ? Icons.volume_off
            : (vol < 0.5 ? Icons.volume_down : Icons.volume_up);
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(icon, size: 20),
              constraints: const BoxConstraints.tightFor(width: 34, height: 40),
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: vol <= 0 ? 'Activar sonido' : 'Silenciar',
              onPressed: player.toggleMute,
            ),
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 11,
                  ),
                ),
                child: Slider(
                  value: vol.clamp(0.0, 1.0),
                  onChanged: player.setVolume,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
