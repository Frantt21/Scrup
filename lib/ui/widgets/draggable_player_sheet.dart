import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';
import 'cover_image.dart';

/// Contenedor ARRASTRABLE con el reproductor COMPLETO de Android: un bottom
/// sheet que se desliza desde la base con un "peek", se puede subir/bajar y
/// estirar casi a pantalla completa. Contiene artwork, título, artista, barra
/// de progreso con seek y los controles de reproducción.
class DraggablePlayerSheet extends StatelessWidget {
  const DraggablePlayerSheet({super.key});

  /// Abre el sheet como bottom sheet modal, devolviendo el `Future` que
  /// permite esperarlo desde quien lo invoca.
  static Future<void> open(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => const DraggablePlayerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.34,
      maxChildSize: 0.94,
      snap: true,
      snapSizes: const [0.34, 0.6, 0.94],
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: _PlayerContent(scrollController: scrollController),
          ),
        );
      },
    );
  }
}

class _PlayerContent extends StatefulWidget {
  final ScrollController scrollController;

  const _PlayerContent({required this.scrollController});

  @override
  State<_PlayerContent> createState() => _PlayerContentState();
}

class _PlayerContentState extends State<_PlayerContent> {
  late final PlayerService _player;
  Track? _track;
  Duration _pos = Duration.zero;
  Duration? _dur;
  bool _playing = false;
  bool _buffering = false;
  bool _dragging = false;
  double _dragValue = 0;

  final List<StreamSubscription> _subs = [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerService>();
    _track = _player.currentTrackValue;
    _pos = _player.positionValue;
    _dur = _player.durationValue;
    _playing = _player.isPlaying;
    _subs.addAll([
      _player.currentTrack.listen((t) {
        if (!mounted) return;
        setState(() => _track = t);
        if (t != null) _ticker ??= _startTicker();
      }),
      _player.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      }),
      _player.buffering.listen((b) {
        if (!mounted) return;
        setState(() => _buffering = b);
      }),
      _player.position.listen((p) {
        if (!mounted) return;
        if (_dragging) return;
        setState(() => _pos = p);
      }),
      _player.duration.listen((d) {
        if (!mounted) return;
        setState(() => _dur = d);
      }),
    ]);
    if (_playing) _ticker = _startTicker();
  }

  Timer? _startTicker() {
    return Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _dragging) return;
      final pos = _player.positionValue;
      if (pos != _pos) setState(() => _pos = pos);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  double get _maxProgress {
    final d = _dur?.inMilliseconds ?? 0;
    return d > 0 ? d.toDouble() : 0;
  }

  double get _progress {
    if (_maxProgress <= 0) return 0;
    return (_dragging ? _dragValue : _pos.inMilliseconds.toDouble())
        .clamp(0.0, _maxProgress)
        .toDouble();
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) {
      final mm = d.inHours * 60 + d.inMinutes.remainder(60);
      return '$mm:${s.toString().padLeft(2, '0')}';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent =
        context.watch<ThemeController>().accentColor ?? cs.primary;

    final track = _track;
    final dur = _dur;
    final total = _maxProgress;

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
      children: [
        // Handle de arrastre
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Artwork
        Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: track != null && track.thumbnailUrl != null
                    ? CoverImage(
                        source: track.thumbnailUrl!,
                        fit: BoxFit.cover,
                        fallback: _fallback(theme),
                      )
                    : _fallback(theme),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Título + artista
        Text(
          track?.title ?? 'Scrup',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: track == null ? cs.onSurfaceVariant : null,
          ),
        ),
        if (track != null && track.artist.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Barra de progreso
        Slider(
          value: _progress.clamp(0.0, total <= 0 ? 1 : total).toDouble(),
          max: total <= 0 ? 1 : total,
          activeColor: accent,
          inactiveColor: cs.surfaceContainerHighest,
          onChangeStart: (_) => setState(() => _dragging = true),
          onChanged: (v) => setState(() => _dragValue = v),
          onChangeEnd: (v) {
            _player.seek(Duration(milliseconds: v.round()));
            setState(() {
              _dragging = false;
              _pos = Duration(milliseconds: v.round());
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(_dragging
                    ? Duration(milliseconds: _dragValue.round())
                    : _pos),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              Text(
                _fmt(dur),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Controles
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ModeButton(
              icon: Icons.shuffle_rounded,
              active: _player.shuffle.value,
              accent: accent,
              onPressed: _player.toggleShuffle,
            ),
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              size: 34,
              onPressed: track == null ? null : _player.previous,
            ),
            _PlayPauseButton(
              playing: _playing,
              accent: accent,
              onPressed: track == null ? null : _player.togglePlayPause,
            ),
            _ControlButton(
              icon: Icons.skip_next_rounded,
              size: 34,
              onPressed: track == null ? null : _player.next,
            ),
            _ModeButton(
              icon: _repeatIcon(_player.repeatMode.value),
              active: _player.repeatMode.value != LoopMode.off,
              accent: accent,
              onPressed: _player.toggleRepeat,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_buffering && track != null) ...[
          const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  IconData _repeatIcon(LoopMode mode) {
    switch (mode) {
      case LoopMode.off:
        return Icons.repeat_rounded;
      case LoopMode.all:
        return Icons.repeat_rounded;
      case LoopMode.one:
        return Icons.repeat_one_rounded;
    }
  }

  Widget _fallback(ThemeData theme) {
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 56,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      iconSize: size,
      color: cs.onSurface,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool playing;
  final Color accent;
  final VoidCallback? onPressed;

  const _PlayPauseButton({
    required this.playing,
    required this.accent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.4),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: IconButton(
        iconSize: 40,
        color: Color.lerp(accent, Colors.black, 0.4) ?? Colors.black,
        onPressed: onPressed,
        icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color accent;
  final VoidCallback onPressed;

  const _ModeButton({
    required this.icon,
    required this.active,
    required this.accent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      iconSize: 22,
      color: active ? accent : cs.onSurfaceVariant,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
