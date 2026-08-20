import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/deezer_service.dart';
import '../../services/player_service.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/settings_store.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';
import '../widgets/context_menu_item.dart';
import 'cover_image.dart';
import 'scrup_toasts.dart';

/// Espacio vertical que ocupa el player flotante en la parte inferior de la
/// ventana (barra + márgenes). Los scrollables de las vistas lo usan como
/// padding inferior para que sus últimos items queden accesibles por encima
/// del player.
const double kPlayerOverlayInset = 104;

/// Margen inferior de los contenedores principales (detalle de playlist y
/// configuración) para que terminen POR ENCIMA del player: el borde superior
/// del cristal del player queda a 76px del borde inferior del área (12 de
/// padding inferior + 64 de barra; el padding superior de 8 es transparente,
/// no suma al vidrio visible), y el contenedor debe quedar a 12px de él — el
/// mismo hueco que separa al contenedor del sidebar y del borde derecho,
/// para espaciados uniformes y simétricos (76 + 12 = 88).
const double kPlayerClearance = 88;

/// Player flotante tipo glass: tarjeta translúcida con blur que flota sobre
/// el contenido. La barra de progreso (sin dot, con tiempos) queda entre la
/// información de la canción (izquierda) y el control de volumen (derecha),
/// con los controles de reproducción encima.
class PlayerBar extends StatefulWidget {
  /// `true` si el panel de la cola está abierto (el botón se resalta).
  final bool queueOpen;

  /// `true` si la vista de lyrics está abierta (el botón se resalta).
  final bool lyricsOpen;

  /// Abre/cierra la vista de lyrics (lo gestiona el AppShell, que la monta
  /// en el IndexedStack).
  final VoidCallback onToggleLyrics;

  /// Abre/cierra el panel de la cola (lo gestiona el AppShell, que monta el
  /// panel en el Row para que empuje el contenido).
  final VoidCallback onToggleQueue;

  const PlayerBar({
    super.key,
    this.queueOpen = false,
    this.lyricsOpen = false,
    required this.onToggleLyrics,
    required this.onToggleQueue,
  });

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  Track? _track;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _buffering = false;

  /// Intervalo mínimo entre repintados de la posición (throttle): el stream
  /// de posición de media_kit emite decenas de ticks por segundo durante la
  /// reproducción, y cada repintado compone la ventana (contribuye al
  /// consumo de GPU aunque la animación esté desactivada). Con ~250ms (4
  /// repintados/s) la barra de progreso se ve fluida y el coste es mínimo
  /// (y al pausar, el stream se detiene: 0%). El throttle del origen está en
  /// PlayerService; este es el guarda local del widget.
  static const Duration _positionRefreshInterval = Duration(milliseconds: 250);
  DateTime _lastPositionFrame = DateTime.fromMillisecondsSinceEpoch(0);

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
        // Throttle del repintado: el valor interno se actualiza en cada tick
        // (barato), pero la UI solo se reconstruye si pasó el intervalo
        // mínimo (o la posición volvió a cero, p. ej. al cambiar de pista).
        final now = DateTime.now();
        if (p == Duration.zero ||
            now.difference(_lastPositionFrame) >= _positionRefreshInterval) {
          _lastPositionFrame = now;
          setState(() => _position = p);
        }
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
  /// a una playlist o editar sus metadatos.
  Future<void> _showContextMenu(Offset position) async {
    final track = _track;
    if (track == null) return;
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
      // Recortar el menú a sus esquinas redondeadas: con el menuPadding a
      // cero, el hover de los items queda full-bleed sin desbordar.
      clipBehavior: Clip.antiAlias,
      items: [
        ContextMenuItem(
          value: 'edit',
          icon: Icons.edit,
          label: l10n.editMetadata,
        ),
        ContextMenuItem(
          value: 'add',
          icon: Icons.playlist_add,
          label: l10n.addToPlaylist,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _showEditMetadataDialog(track);
    } else if (action == 'add') {
      await showAddToPlaylistDialog(context, track);
    }
  }

  /// Editor de metadatos de la pista actual (clic derecho → Editar
  /// metadatos): campos para título, artista, álbum y portada. Al guardar,
  /// el track se actualiza en la cola, en la UI y en la base.
  Future<void> _showEditMetadataDialog(Track track) async {
    final saved = await showDialog<Track>(
      context: context,
      builder: (ctx) => _EditMetadataDialog(track: track),
    );
    if (saved == null || !mounted) return;
    final player = context.read<PlayerService>();
    final savedMsg = AppLocalizations.of(context).metadataSaved;
    await player.updateCurrentMetadata(saved);
    showScrupToast(savedMsg, kind: ScrupToastKind.success);
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
    final settings = context.read<SettingsStore>();
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
              blurRadius: 20,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          // El fondo del player y el contenido interactivo viven en capas
          // separadas: una base plana (el tinte del artwork) y, encima, el
          // degradado animado del acento. Sin blur: los paneles son planos y
          // reproducir no produce frames extra (el degradado solo repinta a
          // baja frecuencia, y la barra de progreso con cada tick de
          // posición). Positioned.fill: llena el Stack sin forzar la altura
          // del contenido (que la fija el Material, 64px).
          child: Stack(
            children: [
              // Base plana del player: el tinte del artwork (sin blur).
              Positioned.fill(
                child: DecoratedBox(decoration: BoxDecoration(color: base)),
              ),
              // Degradado estático del acento del artwork sobre la base.
              Positioned.fill(
                child: Builder(
                  builder: (context) {
                    final accent =
                        themeController.accentColor?.withValues(alpha: 0.25) ??
                        theme.colorScheme.primary.withValues(alpha: 0.25);
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.transparent,
                            accent,
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Material(
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
                          // Derecha: botón de cola + volumen
                          Expanded(child: _buildRight(context, theme, player)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
          AppLocalizations.of(context).nothingPlaying,
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
            child: CoverImage(
              source: _track!.thumbnailUrl,
              fit: BoxFit.cover,
              fallback: _artworkFallback(theme),
            ),
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
                        label = AppLocalizations.of(
                          context,
                        ).downloadingPercent((downloadPct * 100).round());
                      } else if (preparingId != null) {
                        label = AppLocalizations.of(context).preparing;
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
    final l10n = AppLocalizations.of(context);
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
            // Shuffle (el icono no cambia; solo se enciende en lila cuando
            // está activo)
            ValueListenableBuilder<bool>(
              valueListenable: player.shuffle,
              builder: (context, on, _) => IconButton(
                icon: Icon(Icons.shuffle, size: iconSize),
                constraints: btnConstraints,
                padding: EdgeInsets.zero,
                color: on ? primary : muted,
                tooltip: on ? l10n.shuffleOn : l10n.shuffle,
                onPressed: player.toggleShuffle,
              ),
            ),
            // Anterior
            IconButton(
              icon: const Icon(Icons.skip_previous),
              constraints: btnConstraints,
              padding: EdgeInsets.zero,
              color: muted,
              tooltip: l10n.previous,
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
                        tooltip: _playing ? l10n.pause : l10n.play,
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
              tooltip: l10n.next,
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
                    LoopMode.off => l10n.repeatOff,
                    LoopMode.all => l10n.repeatAll,
                    LoopMode.one => l10n.repeatOne,
                  },
                  onPressed: player.toggleRepeat,
                );
              },
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
                  ? l10n.removeFromFavorites
                  : l10n.addToFavorites,
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

  /// Derecha: botón de la COLA (abre el panel que empuja el contenido) y,
  /// al lado, el control de volumen compacto (icono con mute + slider corto).
  Widget _buildRight(
    BuildContext context,
    ThemeData theme,
    PlayerService player,
  ) {
    final l10n = AppLocalizations.of(context);
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Lyrics: abre la vista de letras sincronizadas (resaltada en lila
        // cuando está abierta).
        IconButton(
          icon: const Icon(Icons.lyrics_outlined, size: 20),
          constraints: const BoxConstraints.tightFor(width: 34, height: 40),
          padding: EdgeInsets.zero,
          color: widget.lyricsOpen ? primary : muted,
          tooltip: l10n.lyrics,
          onPressed: widget.onToggleLyrics,
        ),
        // Radio (mismo artista al terminar): resaltada en lila cuando está
        // activa.
        ValueListenableBuilder<bool>(
          valueListenable: player.radio,
          builder: (context, on, _) => IconButton(
            icon: Icon(Icons.radio, size: 20, color: on ? primary : muted),
            constraints: const BoxConstraints.tightFor(width: 34, height: 40),
            padding: EdgeInsets.zero,
            tooltip: on ? l10n.radioOn : l10n.radioOff,
            onPressed: player.toggleRadio,
          ),
        ),
        // Cola: resaltada en lila cuando el panel está abierto.
        IconButton(
          icon: const Icon(Icons.queue_music, size: 20),
          constraints: const BoxConstraints.tightFor(width: 34, height: 40),
          padding: EdgeInsets.zero,
          color: widget.queueOpen ? primary : muted,
          tooltip: l10n.queue,
          onPressed: widget.onToggleQueue,
        ),
        const SizedBox(width: 2),
        ValueListenableBuilder<double>(
          valueListenable: player.volume,
          builder: (context, vol, _) {
            final icon = vol <= 0
                ? Icons.volume_off
                : (vol < 0.5 ? Icons.volume_down : Icons.volume_up);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(icon, size: 20),
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  color: muted,
                  tooltip: vol <= 0 ? l10n.unmute : l10n.mute,
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
        ),
      ],
    );
  }
}

/// Diálogo para editar manualmente los metadatos de una pista (título,
/// artista, álbum y portada). Devuelve el [Track] actualizado al pulsar
/// Guardar, o `null` si se cancela. Mismo estilo glass que el resto de
/// diálogos de la app.
class _EditMetadataDialog extends StatefulWidget {
  final Track track;

  const _EditMetadataDialog({required this.track});

  @override
  State<_EditMetadataDialog> createState() => _EditMetadataDialogState();
}

class _EditMetadataDialogState extends State<_EditMetadataDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _album;
  late final TextEditingController _cover;

  /// `true` mientras se busca la metadata en Deezer (spinner en el botón).
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.track.title);
    _artist = TextEditingController(text: widget.track.artist);
    _album = TextEditingController(text: widget.track.album ?? '');
    _cover = TextEditingController(text: widget.track.thumbnailUrl ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _cover.dispose();
    super.dispose();
  }

  /// Construye el track actualizado a partir de los campos (el id y la
  /// duración se conservan: la fuente de audio no cambia).
  Track _buildTrack() {
    final t = widget.track;
    final title = _title.text.trim();
    final artist = _artist.text.trim();
    final album = _album.text.trim();
    final cover = _cover.text.trim();
    return t.copyWith(
      title: title.isEmpty ? t.title : title,
      artist: artist,
      album: album.isEmpty ? null : album,
      thumbnailUrl: cover.isEmpty ? null : cover,
    );
  }

  /// Busca la metadata en Deezer con el título/artista ESCRITOS en los
  /// campos (no la metadata incrustada del video): así el usuario puede
  /// corregir el artista/título y buscar de nuevo. `searchManual` evita la
  /// caché por videoId (si el enriquecimiento automático ya cacheó un
  /// resultado o un `null` para ese video, la búsqueda manual debe
  /// consultar la API igualmente). Si no hay coincidencia fiable, deja los
  /// campos intactos y avisa.
  Future<void> _searchDeezer() async {
    if (_searching) return;
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    final artist = _artist.text.trim();
    if (title.isEmpty && artist.isEmpty) return;
    setState(() => _searching = true);
    try {
      final enriched = await context
          .read<DeezerService>()
          .searchManual(title, artist);
      if (!mounted) return;
      if (enriched == null) {
        showScrupToast(l10n.metadataNotFound, kind: ScrupToastKind.error);
        return;
      }
      setState(() {
        _title.text = enriched.title;
        _artist.text = enriched.artist;
        _album.text = enriched.album ?? '';
        _cover.text = enriched.thumbnailUrl ?? '';
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Abre el selector de archivos para elegir una imagen local como portada
  /// de la pista. La imagen se COPIA al directorio de portadas de la app
  /// (sobrevive aunque el archivo original se mueva/borre) y la ruta local
  /// resultante rellena el campo de portada.
  Future<void> _pickLocalCover() async {
    final l10n = AppLocalizations.of(context);
    final images = XTypeGroup(
      label: l10n.images,
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;
    try {
      final dest = await copyTrackCoverToAppDir(
        widget.track.id,
        file.path,
      );
      if (!mounted) return;
      setState(() => _cover.text = dest);
    } catch (_) {
      if (!mounted) return;
      showScrupToast(
        l10n.metadataCoverError,
        kind: ScrupToastKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          // Fondo sólido (sin borde ni gradiente translúcido).
          color: theme.colorScheme.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.editMetadata,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.metadataSearchHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.close,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(
                    l10n.metadataTitle,
                    _title,
                    Icons.music_note,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l10n.metadataArtist,
                    _artist,
                    Icons.person,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l10n.metadataAlbum,
                    _album,
                    Icons.album,
                  ),
                  const SizedBox(height: 16),
                  // Portada: miniatura en vivo + campo de URL + botón para
                  // elegir una imagen local (se copia al dir de la app).
                  _field(
                    l10n.metadataCoverUrl,
                    _cover,
                    Icons.link,
                    trailing: IconButton(
                      icon: const Icon(Icons.photo_library, size: 20),
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.chooseImage,
                      onPressed: _pickLocalCover,
                    ),
                    onChanged: (_) => setState(() {}),
                    preview: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: CoverImage(
                          source: _cover.text.trim().isEmpty
                              ? null
                              : _cover.text.trim(),
                          fit: BoxFit.cover,
                          fallback: Container(
                            color: theme.colorScheme.surfaceContainerHigh,
                            child: Icon(
                              Icons.image,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Buscar en Deezer (autocompleta los campos) junto a
                  // Cancelar/Guardar.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: _searching ? null : _searchDeezer,
                        icon: _searching
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome, size: 16),
                        label: Text(l10n.metadataSearchDeezer),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(l10n.cancel),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(context, _buildTrack()),
                            child: Text(l10n.save),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Campo con su label como título ENCIMA (fuera del borde del input) y el
  /// input debajo. [trailing] permite un botón extra dentro del input (p. ej.
  /// elegir imagen) y [preview] una miniatura al lado (p. ej. la portada).
  Widget _field(
    String label,
    TextEditingController controller,
    IconData icon, {
    Widget? trailing,
    ValueChanged<String>? onChanged,
    Widget? preview,
  }) {
    final theme = Theme.of(context);
    final input = TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: label,
        prefixIcon: Icon(icon, size: 18),
        suffixIcon: trailing,
        filled: true,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      style: theme.textTheme.bodyMedium,
      onChanged: onChanged,
    );
    final field = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        input,
      ],
    );
    if (preview == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: field),
        const SizedBox(width: 12),
        preview,
      ],
    );
  }
}


