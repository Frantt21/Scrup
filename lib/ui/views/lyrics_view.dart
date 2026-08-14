import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../core/synced_lyrics.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';
import '../theme_controller.dart';
import '../widgets/lyrics_display.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;

/// Vista de letras sincronizadas: contenedor glass (igual que Inicio/Buscar)
/// montado en el IndexedStack del AppShell. Muestra las lyrics de la pista
/// en reproducción con auto-scroll, karaoke sweep y tap-to-seek.
class LyricsView extends StatefulWidget {
  /// Vuelve a la vista anterior (home/búsqueda).
  final VoidCallback onBack;

  const LyricsView({super.key, required this.onBack});

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Track? _track;
  SyncedLyrics? _lyrics;

  /// `true` mientras se busca en LRCLIB (spinner en el estado vacío).
  bool _loading = false;

  final ValueNotifier<int?> _currentIndex = ValueNotifier<int?>(null);
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);

  /// Desfase de sincronización ajustado por el usuario (tap en una línea
  /// respeta el offset; el sweep también).
  Duration _lyricsOffset = Duration.zero;

  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  /// Contador para descartar búsquedas obsoletas (cambio rápido de canción).
  int _fetchToken = 0;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    _track = player.currentTrackValue;
    _position.value = player.positionValue;
    final dur = player.durationValue;
    if (dur != null) _duration.value = dur;

    _trackSub = player.currentTrack.listen((t) {
      if (!mounted) return;
      setState(() {
        _track = t;
        _lyrics = null;
        _lyricsOffset = Duration.zero;
        _currentIndex.value = null;
      });
      _fetchLyrics(t);
    });
    _positionSub = player.position.listen((p) {
      if (!mounted) return;
      _position.value = p;
      final lyrics = _lyrics;
      if (lyrics != null) {
        final idx = lyrics.getCurrentLineIndex(p - _lyricsOffset);
        if (idx != _currentIndex.value) _currentIndex.value = idx;
      }
    });
    _durationSub = player.duration.listen((d) {
      if (!mounted) return;
      if (d != null) _duration.value = d;
    });

    // Buscar las letras de la pista actual al abrir.
    final track = _track;
    if (track != null) _fetchLyrics(track);
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _currentIndex.dispose();
    _position.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// Busca las letras de [track] en LRCLIB (con caché en disco/memoria).
  Future<void> _fetchLyrics(Track? track) async {
    if (track == null) return;
    final token = ++_fetchToken;
    setState(() => _loading = true);
    try {
      final lyrics = await context
          .read<LyricsService>()
          .fetchLyrics(track.title, track.artist);
      if (!mounted || token != _fetchToken) return;
      setState(() {
        _lyrics = lyrics;
        _loading = false;
      });
      if (lyrics != null) {
        _currentIndex.value =
            lyrics.getCurrentLineIndex(_position.value - _lyricsOffset);
      }
    } catch (_) {
      if (!mounted || token != _fetchToken) return;
      setState(() => _loading = false);
    }
  }

  /// Tap en una línea: seek a ese timestamp (respetando el offset).
  void _onLineTap(Duration timestamp) {
    final player = context.read<PlayerService>();
    final target = timestamp + _lyricsOffset;
    player.seek(target);
  }

  /// Busca el archivo de audio cacheado de la pista (para la waveform).
  Future<String?> _audioPathOf(Track track) async {
    try {
      return await context.read<AudioCacheService>().cachedPath(track.id);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // El acento del artwork de la pista tiñe las letras.
    final accent = context.watch<ThemeController>().accentColor;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, kPlayerClearance),
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
            // Fondo plano (sin gradiente translúcido): las letras del color
            // de la canción se leen sobre él.
            color: theme.colorScheme.surfaceContainer,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 24, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: l10n.backToHome,
                      onPressed: widget.onBack,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.lyricsTitle,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_track != null)
                            Text(
                              '${_track!.title} — ${_track!.artist}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Refrescar / re-buscar (p. ej. si el usuario guardó
                    // lyrics manuales o corrigió la metadata).
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: l10n.refreshLyrics,
                      onPressed: () => _fetchLyrics(_track),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(theme, l10n, accent)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    AppLocalizations l10n,
    Color? accent,
  ) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final track = _track;
    if (track == null) {
      return Center(
        child: Text(
          l10n.lyricsNoTrack,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final lyrics = _lyrics;
    if (lyrics == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 56,
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.lyricsNotFound,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.lyricsNotFoundHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<String?>(
      future: _audioPathOf(track),
      builder: (context, snapshot) {
        return LyricsDisplay(
          lyrics: lyrics,
          currentIndexNotifier: _currentIndex,
          positionNotifier: _position,
          durationNotifier: _duration,
          audioPath: snapshot.data,
          lyricsOffset: _lyricsOffset,
          onTap: _onLineTap,
          accentColor: accent,
        );
      },
    );
  }
}
