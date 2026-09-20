import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/audio_cache_service.dart';
import '../../services/player_service.dart';
import '../playlist_actions.dart';
import '../theme_controller.dart';
import '../widgets/context_menu_item.dart';
import 'cover_image.dart';
import 'edit_metadata_dialog.dart';
import 'scrup_toasts.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/palette_cache_store.dart';

const double kPlayerOverlayInset = 104;
const double kPlayerClearance = 88;

/// Floating glass player bar with progress, controls and volume.
class PlayerBar extends StatefulWidget {
  final bool queueOpen;
  final bool lyricsOpen;
  final VoidCallback onToggleLyrics;
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

class _PlayerBarState extends State<PlayerBar>
    with SingleTickerProviderStateMixin {
  Track? _track;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _buffering = false;

  late final AnimationController _swipeCtrl;
  int _swipeDir = 1;
  int _pendingSwipeDir = 1;
  static const Duration _positionRefreshInterval = Duration(milliseconds: 250);
  DateTime _lastPositionFrame = DateTime.fromMillisecondsSinceEpoch(0);
  double? _dragValue;
  int _favoritesId = -1;
  bool _isFavorite = false;

  StreamSubscription<bool>? _favSub;

  final List<StreamSubscription> _subs = [];

  Timer? _nullTrackTimer;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    final db = context.read<AppDatabase>();
    _swipeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _track = player.currentTrackValue;
    _duration = player.durationValue;
    _subs.addAll([
      player.currentTrack.listen((t) {
        if (!mounted) return;
        if (t == null) {
          _nullTrackTimer?.cancel();
          _nullTrackTimer = Timer(const Duration(milliseconds: 80), () {
            if (mounted) setState(() { _track = null; _dragValue = null; });
          });
          return;
        }
        _nullTrackTimer?.cancel();
        final changed = t.id != _track?.id;
        setState(() {
          _track = t;
          _dragValue = null;
        });
        if (changed) {
          _swipeDir = _pendingSwipeDir;
          _pendingSwipeDir = 1;
          _swipeCtrl.forward(from: 0);
        }
        _refreshFavoriteState();
      }),
      player.position.listen((p) {
        if (!mounted) return;
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
    unawaited(_setupFavorites(db));
  }

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

  Future<void> _showContextMenu(Offset position) async {
    final track = _track;
    if (track == null) return;
    final l10n = AppLocalizations.of(context);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      clipBehavior: Clip.antiAlias,
      items: [
        ContextMenuItem(
          value: 'fav',
          icon: _isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: _isFavorite
              ? l10n.removeFromFavorites
              : l10n.addToFavorites,
        ),
        ContextMenuItem(
          value: 'edit',
          icon: Icons.edit_rounded,
          label: l10n.editMetadata,
        ),
        ContextMenuItem(
          value: 'add',
          icon: Icons.playlist_add_rounded,
          label: l10n.addToPlaylist,
        ),
        ContextMenuItem(
          value: 'link',
          icon: Icons.link_rounded,
          label: l10n.copyLink,
        ),
        ContextMenuItem(
          value: 'recalc',
          icon: Icons.palette_rounded,
          label: l10n.recalcColors,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'fav') {
      await toggleTrackFavorite(context, track, current: _isFavorite);
    } else if (action == 'edit') {
      await _showEditMetadataDialog(track);
    } else if (action == 'add') {
      await showAddToPlaylistDialog(context, track);
    } else if (action == 'link') {
      await Clipboard.setData(ClipboardData(text: track.youtubeUrl));
      if (!mounted) return;
      showScrupToast(l10n.copyLink, kind: ScrupToastKind.success);
    } else if (action == 'recalc') {
      await _recalcTrackColors(track);
    }
  }

  Future<void> _showEditMetadataDialog(Track track) async {
    final saved = await showDialog<Track>(
      context: context,
      builder: (ctx) => EditMetadataDialog(track: track),
    );
    if (saved == null || !mounted) return;
    final player = context.read<PlayerService>();
    final savedMsg = AppLocalizations.of(context).metadataSaved;
    await player.updateCurrentMetadata(saved);
    showScrupToast(savedMsg, kind: ScrupToastKind.success);
  }

  Future<void> _recalcTrackColors(Track track) async {
    final url = track.thumbnailUrl;
    final l10n = AppLocalizations.of(context);
    if (url == null || url.isEmpty) return;
    final store = context.read<PaletteCacheStore>();
    await ArtworkPaletteService.trioFor(
      url,
      store,
      force: true,
      artworkCache: context.read<ArtworkCacheService>(),
    );
    if (mounted) {
      context.read<ThemeController>().invalidateColor(url);
      if (_track?.thumbnailUrl == url) {
        final newAccent = store.get(url);
        context.read<ThemeController>().setAccent(newAccent);
      }
      showScrupToast(l10n.colorsUpdated, kind: ScrupToastKind.success);
    }
  }

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
    _nullTrackTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _swipeCtrl.dispose();
    super.dispose();
  }

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
    final shownProgress = _dragValue ?? progress;
    final shownPosition = _dragValue != null
        ? Duration(milliseconds: (_dragValue! * total.inMilliseconds).round())
        : _position;

    // Fondo PLANO de acento (mismo lenguaje que el player expandido de
    // Android) con contenido en contraste automático (negro sobre acentos
    // claros, blanco sobre oscuros).
    final accent =
        themeController.accentColor ?? theme.colorScheme.primary;
    final onAccent = accent.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    final mutedAccent = onAccent.withValues(alpha: 0.65);

    return GestureDetector(
      onSecondaryTapUp: (details) => _showContextMenu(details.globalPosition),
      child: Container(
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
          child: Stack(
            children: [
              // Acento plano con crossfade al cambiar de pista (350ms,
              // como el _AccentBackground de Android).
              Positioned.fill(
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: accent),
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  builder: (context, color, _) {
                    return DecoratedBox(
                      decoration: BoxDecoration(color: color ?? accent),
                    );
                  },
                ),
              ),
              Material(
                color: Colors.transparent,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildTrackInfo(
                              theme,
                              cache,
                              player,
                              onAccent: onAccent,
                              mutedAccent: mutedAccent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _buildControls(
                                  theme,
                                  player,
                                  hasTrack,
                                  accent: onAccent,
                                ),
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
                                                color: mutedAccent,
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
                                            activeTrackColor: onAccent,
                                            // Pista restante también en color
                                            // de contraste (el default del
                                            // tema no se adapta al acento).
                                            inactiveTrackColor: onAccent
                                                .withValues(alpha: 0.30),
                                            thumbColor: onAccent,
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
                                                color: mutedAccent,
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
                          Expanded(
                            child: _buildRight(
                              context,
                              theme,
                              player,
                              onAccent: onAccent,
                              mutedAccent: mutedAccent,
                            ),
                          ),
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

  Widget _buildTrackInfo(
    ThemeData theme,
    AudioCacheService cache,
    PlayerService player, {
    required Color onAccent,
    required Color mutedAccent,
  }) {
    if (_track == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AppLocalizations.of(context).nothingPlaying,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: mutedAccent,
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _swipeCtrl,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_swipeCtrl.value);
        return Opacity(
          opacity: t,
          child: FractionalTranslation(
            translation: Offset(_swipeDir * (1 - t) * 0.35, 0),
            child: child,
          ),
        );
      },
      child: Row(
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
          Flexible(
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
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: onAccent,
                          ),
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
                    color: mutedAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(
              _isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: 18,
            ),
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            tooltip: _isFavorite
                ? AppLocalizations.of(context).removeFromFavorites
                : AppLocalizations.of(context).addToFavorites,
            color: _isFavorite ? onAccent : mutedAccent,
            onPressed: _toggleFavorite,
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
    ThemeData theme,
    PlayerService player,
    bool hasTrack, {
    required Color accent,
  }) {
    final l10n = AppLocalizations.of(context);
    const tileH = 36.0;

    return ValueListenableBuilder<String?>(
      valueListenable: player.preparingTrackId,
      builder: (context, preparingId, _) {
        final preparing = preparingId != null;

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: player.shuffle,
              builder: (context, on, _) => _TileButton(
                width: 36,
                height: tileH,
                radius: 12,
                icon: Icons.shuffle_rounded,
                iconSize: 22,
                color: on ? accent : accent.withValues(alpha: 0.45),
                tooltip: on ? l10n.shuffleOn : l10n.shuffle,
                onTap: player.toggleShuffle,
              ),
            ),
            const SizedBox(width: 6),
            _TileButton(
              width: 48,
              height: tileH,
              radius: 12,
              icon: Icons.skip_previous_rounded,
              iconSize: 22,
              color: accent,
              tooltip: l10n.previous,
              onTap: hasTrack
                  ? () {
                      _pendingSwipeDir = -1;
                      player.previous();
                    }
                  : null,
            ),
            const SizedBox(width: 6),
            _TileButton(
              width: 48,
              height: tileH,
              radius: 12,
              icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              iconSize: 26,
              color: accent,
              tooltip: _playing ? l10n.pause : l10n.play,
              loading: preparing || _buffering,
              onTap: hasTrack ? player.togglePlayPause : null,
            ),
            const SizedBox(width: 6),
            _TileButton(
              width: 48,
              height: tileH,
              radius: 12,
              icon: Icons.skip_next_rounded,
              iconSize: 22,
              color: accent,
              tooltip: l10n.next,
              onTap: hasTrack
                  ? () {
                      _pendingSwipeDir = 1;
                      player.next();
                    }
                  : null,
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<LoopMode>(
              valueListenable: player.repeatMode,
              builder: (context, mode, _) => _TileButton(
                width: 36,
                height: tileH,
                radius: 12,
                icon: mode == LoopMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                iconSize: 22,
                color: mode != LoopMode.off
                    ? accent
                    : accent.withValues(alpha: 0.45),
                tooltip: switch (mode) {
                  LoopMode.off => l10n.repeatOff,
                  LoopMode.all => l10n.repeatAll,
                  LoopMode.one => l10n.repeatOne,
                },
                onTap: player.toggleRepeat,
              ),
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
        Icons.music_note_rounded,
        size: 22,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildRight(
    BuildContext context,
    ThemeData theme,
    PlayerService player, {
    required Color onAccent,
    required Color mutedAccent,
  }) {
    final l10n = AppLocalizations.of(context);
    // Un SOLO contenedor translúcido redondeado (como el tile ancho de
    // Android con shuffle/repeat/añadir): lyrics | radio | cola | volumen
    // viven juntos dentro del mismo grupo.
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: onAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.lyrics_rounded, size: 20),
              constraints: const BoxConstraints.tightFor(width: 30, height: 36),
              padding: EdgeInsets.zero,
              color: widget.lyricsOpen ? onAccent : mutedAccent,
              tooltip: l10n.lyrics,
              onPressed: widget.onToggleLyrics,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: player.radio,
              builder: (context, on, _) => IconButton(
                icon: Icon(
                  Icons.radio_rounded,
                  size: 20,
                  color: on ? onAccent : mutedAccent,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                tooltip: on ? l10n.radioOn : l10n.radioOff,
                onPressed: player.toggleRadio,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.queue_music_rounded, size: 20),
              constraints: const BoxConstraints.tightFor(width: 30, height: 36),
              padding: EdgeInsets.zero,
              color: widget.queueOpen ? onAccent : mutedAccent,
              tooltip: l10n.queue,
              onPressed: widget.onToggleQueue,
            ),
            Tooltip(
              message: l10n.audioOutput,
              child: _VolumeSection(player: player, muted: mutedAccent, onAccent: onAccent),
            ),
          ],
        ),
      ),
    );
  }
}

/// Volume control with audio device selector.
class _VolumeSection extends StatefulWidget {
  final PlayerService player;
  final Color muted;

  /// Color de contraste (negro/blanco según el acento) para el chevron
  /// en hover.
  final Color? onAccent;

  const _VolumeSection({required this.player, required this.muted, this.onAccent});

  @override
  State<_VolumeSection> createState() => _VolumeSectionState();
}

class _VolumeSectionState extends State<_VolumeSection> {
  bool _hovering = false;

  void _showDeviceMenu(BuildContext anchorContext) {
    final player = widget.player;
    final devices = player.audioDevices.value;
    final current = player.audioDevice.value;
    if (devices.isEmpty) return;

    final renderBox = anchorContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(anchorContext).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromCenter(
        center: renderBox.localToGlobal(
          renderBox.size.center(Offset.zero),
          ancestor: overlay,
        ),
        width: 200,
        height: 0,
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: anchorContext,
      position: position,
      constraints: const BoxConstraints(minWidth: 200, maxHeight: 300),
      clipBehavior: Clip.antiAlias,
      items: devices.map((d) {
        final isAuto = d.name == 'auto' || d.name.isEmpty;
        final label = isAuto ? 'Auto' : d.description;
        final selected = d.name == current.name;
        return PopupMenuItem<String>(
          value: d.name,
          child: Row(
            children: [
              if (selected)
                Icon(Icons.check_rounded,
                    size: 16,
                    color: Theme.of(anchorContext).colorScheme.primary)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    ).then((selectedName) {
      if (selectedName == null) return;
      final device = devices.firstWhere(
        (d) => d.name == selectedName,
        orElse: () => AudioDevice.auto(),
      );
      player.setAudioDevice(device);
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: player.volume,
      builder: (context, vol, _) {
        final icon = vol <= 0
            ? Icons.volume_off_rounded
            : (vol < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono de volumen con mute (SIEMPRE contraste puro, sin
            // atenuar: negro/blanco según el acento).
            IconButton(
              icon: Icon(icon, size: 20),
              constraints: const BoxConstraints.tightFor(
                width: 34,
                height: 40,
              ),
              padding: EdgeInsets.zero,
              color: widget.onAccent ?? widget.muted,
              tooltip: vol <= 0 ? l10n.unmute : l10n.mute,
              onPressed: player.toggleMute,
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              mouseCursor: SystemMouseCursors.click,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onTap: () => _showDeviceMenu(context),
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovering = true),
                onExit: (_) => setState(() => _hovering = false),
                child: AnimatedRotation(
                  turns: _hovering ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: _hovering
                        ? (widget.onAccent ?? theme.colorScheme.primary)
                        : widget.muted,
                  ),
                ),
              ),
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
                  // Contraste sobre el fondo de acento del player.
                  activeTrackColor:
                      widget.onAccent ?? theme.colorScheme.primary,
                  inactiveTrackColor: (
                    widget.onAccent ?? theme.colorScheme.primary
                  ).withValues(alpha: 0.30),
                  thumbColor: widget.onAccent ?? theme.colorScheme.primary,
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

/// Botón "tile" del transporte: contenedor translúcido redondeado con el
/// glifo centrado (mismo lenguaje visual que el player expandido de Android:
/// white @ 10% sobre el fondo, radio 12 y altura contenida en la barra).
class _TileButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final double width;
  final double height;
  final double radius;
  final Color color;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool loading;

  const _TileButton({
    required this.icon,
    required this.iconSize,
    required this.width,
    required this.height,
    required this.radius,
    required this.color,
    this.tooltip,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final Widget button = Opacity(
      opacity: onTap == null ? 0.45 : 1.0,
      child: Material(
        color: color.withValues(alpha: onTap == null ? 0.06 : 0.10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: iconSize - 4,
                      height: iconSize - 4,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Icon(icon, size: iconSize, color: color),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
