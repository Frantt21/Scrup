import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show Gradient, ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';
import '../../services/settings_store.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';
import '../widgets/context_menu_item.dart';

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

  /// Abre/cierra el panel de la cola (lo gestiona el AppShell, que monta el
  /// panel en el Row para que empuje el contenido).
  final VoidCallback onToggleQueue;

  const PlayerBar({
    super.key,
    this.queueOpen = false,
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
  /// reproducción, y cada setState repinta todo el cristal del player
  /// (incluido el blur) — es lo que dispara el consumo de CPU/GPU aunque la
  /// animación esté desactivada. Con ~150ms el progreso se ve fluido y el
  /// coste baja a casi cero (y al pausar, el stream se detiene: 0%).
  static const Duration _positionRefreshInterval = Duration(milliseconds: 150);
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
  /// a una playlist.
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
          value: 'add',
          icon: Icons.playlist_add,
          label: l10n.addToPlaylist,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await showAddToPlaylistDialog(context, track);
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
          // El cristal (blur), el degradado y el contenido interactivo viven
          // en capas separadas. El BackdropFilter solo envuelve una capa base
          // translúcida ESTÁTICA (el tinte del vidrio), de modo que el blur
          // únicamente se re-evalúa cuando cambia el contenido de DETRÁS
          // (scroll, cambio de vista) — y por eso al pausar bajaba a 0%: el
          // stream de posición se detiene y no hay repintados. Antes, cada
          // repintado de la barra de progreso (varias veces por segundo) y
          // cada frame del degradado re-evaluaban el blur sobre el fondo:
          // era la causa principal del consumo de GPU al reproducir.
          child: Stack(
            children: [
              // Capa del cristal: difumina el contenido que pasa por detrás.
              // El hijo es estático (nunca se repinta), así que el blur no se
              // re-evalúa por los repintados de la barra.
              Positioned.fill(
                child: BackdropFilter(
                  // Cristal: difumina el contenido que pasa por detrás
                  filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: DecoratedBox(decoration: BoxDecoration(color: base)),
                ),
              ),
              // Degradado (barrido del acento del artwork) ENCIMA del
              // cristal, fuera del blur: se repinta sin re-evaluar el blur.
              // El barrido usa extremos transparentes (el tinte base lo pone
              // la capa del cristal). La animación se puede desactivar desde
              // Configuración: el ValueNotifier del SettingsStore reacciona
              // al instante y se muestra un degradado estático (congelado en
              // el centro). Positioned.fill: llena el Stack sin forzar la
              // altura del contenido (que la fija el Material, 64px).
              Positioned.fill(
                child: ValueListenableBuilder<bool>(
                  valueListenable: settings.playerAnimationEnabled,
                  builder: (context, animated, _) {
                    final accent =
                        themeController.accentColor?.withValues(alpha: 0.25) ??
                        theme.colorScheme.primary.withValues(alpha: 0.25);
                    if (animated) {
                      return _AnimatedPlayerGradient(
                        toneA: accent,
                        toneB: Colors.transparent,
                      );
                    }
                    // Estático: mismo degradado pero sin movimiento.
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
                tooltip: on ? l10n.radioOn : l10n.radioOff,
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
        // Cola primero: resaltada en lila cuando el panel está abierto.
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

/// Degradado animado de dos tonos para el cristal del player: un barrido
/// sutil del acento sobre el fondo oscuro translúcido, que se mueve
/// ligeramente. Optimizado: el [CustomPainter] se suscribe al controller vía
/// `repaint`, así solo se repinta el canvas (sin reconstruir widgets por
/// frame), y la animación se pausa cuando no hay reproducción.
class _AnimatedPlayerGradient extends StatefulWidget {
  /// Tono de acento (color del artwork, o lila por defecto).
  final Color toneA;

  /// Tono oscuro translúcido base del cristal.
  final Color toneB;

  const _AnimatedPlayerGradient({required this.toneA, required this.toneB});

  @override
  State<_AnimatedPlayerGradient> createState() =>
      _AnimatedPlayerGradientState();
}

class _AnimatedPlayerGradientState extends State<_AnimatedPlayerGradient> {
  /// Frecuencia del barrido: ~7fps. El degradado se mueve MUY despacio
  /// (ciclo de 10s): el pico del barrido avanza ~2% del ancho por frame, así
  /// que 7 frames por segundo se ven idénticos a 60.
  ///
  /// No se usa [AnimationController] a propósito: un Ticker activo obliga al
  /// engine a producir un frame en cada vsync (60fps) aunque la escena no
  /// cambie visiblemente — era la principal fuente del consumo de CPU/GPU
  /// durante la reproducción (cada frame además re-evalúa el blur del
  /// cristal). Un [Timer] solo repinta al avanzar: 15 frames/s.
  static const Duration _frameInterval = Duration(milliseconds: 150);

  /// Duración de un ciclo completo del barrido (10s, como antes).
  static const int _cycleMillis = 10000;

  Timer? _timer;

  /// Fase 0..1 del barrido; el painter la lee vía `repaint` (solo repinta
  /// cuando este notifier cambia).
  final ValueNotifier<double> _frame = ValueNotifier<double>(0);
  StreamSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    // Optimización: solo animar mientras hay reproducción (pausado o sin
    // pista, el degradado queda estático y no consume frames).
    final player = context.read<PlayerService>();
    _playingSub = player.playing.listen((playing) {
      if (playing) {
        _start();
      } else {
        _stop();
      }
    });
    if (player.isPlaying) _start();
  }

  void _start() {
    _timer ??= Timer.periodic(_frameInterval, (_) {
      _frame.value =
          (_frame.value + _frameInterval.inMilliseconds / _cycleMillis) % 1.0;
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _stop();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MovingGradientPainter(
        toneA: widget.toneA,
        toneB: widget.toneB,
        animation: _frame,
      ),
    );
  }
}

/// Pinta el degradado de dos tonos con el centro del barrido oscilando
/// lentamente (izquierda ↔ derecha). Repinta solo el canvas (`repaint`).
class _MovingGradientPainter extends CustomPainter {
  final Color toneA;
  final Color toneB;
  final ValueListenable<double> animation;

  _MovingGradientPainter({
    required this.toneA,
    required this.toneB,
    required this.animation,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    // Onda suave -1..1 (un ciclo por vuelta): el barrido va y viene.
    final wave = math.sin(animation.value * 2 * math.pi);
    // Centro del acento: oscila entre el 15% y el 85% del ancho.
    final mid = 0.5 + wave * 0.35;
    final rect = Offset.zero & size;
    final shader = ui.Gradient.linear(
      Offset.zero,
      Offset(size.width, size.height * 0.35),
      [toneB, toneA, toneB],
      [0.0, mid, 1.0],
    );
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_MovingGradientPainter oldDelegate) =>
      oldDelegate.toneA != toneA || oldDelegate.toneB != toneB;
}
