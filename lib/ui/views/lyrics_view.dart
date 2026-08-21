import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:provider/provider.dart';

import '../../core/lyrics_search_result.dart';
import '../../core/track.dart';
import '../../core/synced_lyrics.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';
import '../../services/settings_store.dart';
import '../theme_controller.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyrics_display.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;

/// Vista de letras sincronizadas: contenedor glass (igual que Inicio/Buscar)
/// montado en el IndexedStack del AppShell. Muestra las lyrics de la pista
/// en reproducción con auto-scroll, karaoke sweep, tap-to-seek, búsqueda
/// manual y sincronización manual (port de forawn_mobile).
class LyricsView extends StatefulWidget {
  const LyricsView({super.key});

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  Track? _track;
  SyncedLyrics? _lyrics;

  /// `true` mientras se busca en LRCLIB (spinner en el estado vacío).
  bool _loading = false;

  final ValueNotifier<int?> _currentIndex = ValueNotifier<int?>(null);
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);

  // ── Interpolación de posición para el sweep fluido ──
  // El stream de posición del player viene throttled a ~250ms; el sweep
  // karaoke necesita resolución por frame, así que un Ticker extrapola la
  // posición entre emisiones reales (base + tiempo de pared) y se resincroniza
  // con cada emisión para no acumular deriva.
  late final Ticker _smoothingTick;
  Duration _smoothBasePosition = Duration.zero;
  DateTime _smoothBaseAt = DateTime.now();
  bool _playing = false;

  /// Desfase de sincronización ajustado por el usuario (se resta a la
  /// posición para el índice y el sweep; el tap-to-seek lo suma).
  Duration _lyricsOffset = Duration.zero;

  /// Modo karaoke (sweep palabra por palabra): se refleja en el widget de
  /// lyrics y se persiste vía el SettingsStore.
  bool _sweepEnabled = false;

  StreamSubscription<Track?>? _trackSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<bool>? _playingSub;

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
      // El offset es POR PISTA: cargar el ajuste guardado de esta canción
      // (cambiar de pista o de fuente de letra no lo pierde).
      unawaited(_loadTrackOffset(t));
      _fetchLyrics(t);
    });
    _positionSub = player.position.listen((p) {
      if (!mounted) return;
      // Nueva base de extrapolación (y snap para pausa/seek).
      _smoothBasePosition = p;
      _smoothBaseAt = DateTime.now();
      if (!_playing) _position.value = p;
      _updateCurrentIndex(p);
    });
    _playing = player.isPlaying;
    _playingSub = player.playing.listen((playing) {
      if (!mounted) return;
      _playing = playing;
      final service = context.read<PlayerService>();
      if (playing) {
        _smoothBasePosition = service.positionValue;
        _smoothBaseAt = DateTime.now();
        if (!_smoothingTick.isActive) _smoothingTick.start();
      } else {
        _smoothingTick.stop();
        _position.value = service.positionValue;
      }
    });
    _smoothingTick = createTicker((_) {
      if (!mounted || !_playing) return;
      final estimated =
          _smoothBasePosition + DateTime.now().difference(_smoothBaseAt);
      _position.value = estimated;
      _updateCurrentIndex(estimated);
    });
    if (_playing) {
      _smoothBasePosition = player.positionValue;
      _smoothBaseAt = DateTime.now();
      _smoothingTick.start();
    }
    _durationSub = player.duration.listen((d) {
      if (!mounted) return;
      if (d != null) _duration.value = d;
    });

    // Cargar preferencias (best-effort).
    unawaited(_loadSweepPref());
    unawaited(_loadTrackOffset(_track));

    // Buscar las letras de la pista actual al abrir.
    final track = _track;
    if (track != null) _fetchLyrics(track);
  }

  Future<void> _loadSweepPref() async {
    try {
      final enabled = await context
          .read<SettingsStore>()
          .loadLyricsSweepEnabled();
      if (!mounted) return;
      setState(() => _sweepEnabled = enabled);
    } catch (_) {
      // Best-effort: sin preferencia se queda el default.
    }
  }

  /// Carga el offset POR PISTA y lo aplica si la pista sigue siendo la
  /// actual (una respuesta tardía no pisa el offset de otra canción).
  Future<void> _loadTrackOffset(Track? track) async {
    if (track == null) return;
    try {
      final offset = await context
          .read<SettingsStore>()
          .loadLyricsOffsetFor(track.id);
      if (!mounted || _track?.id != track.id) return;
      setState(() => _lyricsOffset = offset);
      _updateCurrentIndex(_position.value);
    } catch (_) {}
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _smoothingTick.dispose();
    _currentIndex.dispose();
    _position.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// Recalcula el índice de línea actual para [position].
  void _updateCurrentIndex(Duration position) {
    final lyrics = _lyrics;
    if (lyrics == null) return;
    final idx = lyrics.getCurrentLineIndex(position - _lyricsOffset);
    if (idx != _currentIndex.value) _currentIndex.value = idx;
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

  /// Aplica [lyrics] a la pista actual: se muestra al instante y se guarda
  /// en la caché (disco) para las próximas veces. [sourceLrc] es el LRC
  /// original de donde salió [lyrics]: guardarlo tal cual preserva los tags
  /// word-by-word (`toLRC()` los descartaría).
  Future<void> _applyLyrics(SyncedLyrics lyrics, {String? sourceLrc}) async {
    final track = _track;
    if (track == null) return;
    await context
        .read<LyricsService>()
        .saveManualLyrics(track.title, track.artist, sourceLrc ?? lyrics.toLRC());
    if (!mounted) return;
    setState(() {
      _lyrics = lyrics;
      // El offset por pista se CONSERVA: cambiar la fuente de la letra no
      // debe perder la sincronización que el usuario ya ajustó.
      _currentIndex.value =
          lyrics.getCurrentLineIndex(_position.value - _lyricsOffset);
    });
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

  /// Diálogo de búsqueda manual en LRCLIB (con resultados y edición).
  Future<void> _showSearchDialog() async {
    final track = _track;
    if (track == null) return;
    final result = await showDialog<LyricsSearchResult>(
      context: context,
      builder: (ctx) => _LyricsSearchDialog(
        initialQuery: '${track.title} ${track.artist}',
        titleHint: track.title,
        artistHint: track.artist,
        accentColor: context.read<ThemeController>().accentColor,
      ),
    );
    if (result == null || !mounted) return;
    // El resultado puede traer LRC sincronizado o texto plano.
    if (result.syncedLyrics.trim().isNotEmpty) {
      await _applyLyrics(
        SyncedLyrics.fromLRC(
          songTitle: track.title,
          artist: track.artist,
          lrcContent: result.syncedLyrics,
        ),
        sourceLrc: result.syncedLyrics,
      );
    } else if (result.plainLyrics.trim().isNotEmpty) {
      // Letra sin timestamps: se muestra como líneas (el highlight salta).
      await _applyLyrics(
        SyncedLyrics(
          songTitle: track.title,
          artist: track.artist,
          lines: [
            for (final l in result.plainLyrics.split('\n'))
              if (l.trim().isNotEmpty)
                LyricLine(timestamp: Duration.zero, text: l.trim()),
          ],
        ),
      );
    }
  }

  /// Diálogo de sincronización manual (offsets ±100/±500 ms, port de
  /// forawn_mobile): muestra la línea actual/siguiente y ajusta el offset.
  Future<void> _showSyncDialog() async {
    final lyrics = _lyrics;
    if (lyrics == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _LyricsSyncDialog(
        lyrics: lyrics,
        positionNotifier: _position,
        currentIndexNotifier: _currentIndex,
        offset: _lyricsOffset,
        accentColor: context.read<ThemeController>().accentColor,
        onOffsetChanged: (offset) {
          _lyricsOffset = offset;
          _currentIndex.value =
              lyrics.getCurrentLineIndex(_position.value - offset);
          // Persistir POR PISTA: cada canción recuerda su propio ajuste.
          final track = _track;
          if (track != null) {
            context
                .read<SettingsStore>()
                .saveLyricsOffsetFor(track.id, offset);
          }
        },
      ),
    );
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
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    // Artwork a la altura de ambas filas (título + artista).
                    if (_track != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: CoverImage(
                            source: _track!.thumbnailUrl,
                            fit: BoxFit.cover,
                            fallback: Icon(
                              Icons.music_note,
                              size: 22,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Título de la canción como título de la vista.
                          Text(
                            _track?.title ?? l10n.lyricsTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_track != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                _track!.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Modo karaoke (sweep palabra por palabra).
                    IconButton(
                      icon: Icon(
                        Icons.graphic_eq,
                        color: _sweepEnabled
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      tooltip: _sweepEnabled
                          ? l10n.karaokeSweepOn
                          : l10n.karaokeSweepOff,
                      onPressed: () async {
                        final next = !_sweepEnabled;
                        setState(() => _sweepEnabled = next);
                        await context
                            .read<SettingsStore>()
                            .setLyricsSweepEnabled(next);
                      },
                    ),
                    // Sincronización manual (ajuste de offset).
                    IconButton(
                      icon: const Icon(Icons.timer_outlined),
                      tooltip: l10n.syncLyricsTitle,
                      onPressed: _lyrics == null ? null : _showSyncDialog,
                    ),
                    // Búsqueda manual en LRCLIB.
                    IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: l10n.searchLyrics,
                      onPressed: _track == null ? null : _showSearchDialog,
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
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _showSearchDialog,
                icon: const Icon(Icons.search, size: 18),
                label: Text(l10n.searchLyrics),
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
          sweepEnabled: _sweepEnabled,
        );
      },
    );
  }
}

/// Diálogo de sincronización manual: preview de la línea actual/siguiente y
/// botones para desplazar el offset ±100/±500 ms (port de forawn_mobile).
class _LyricsSyncDialog extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueListenable<Duration> positionNotifier;
  final ValueNotifier<int?> currentIndexNotifier;
  final Duration offset;
  final Color? accentColor;
  final ValueChanged<Duration> onOffsetChanged;

  const _LyricsSyncDialog({
    required this.lyrics,
    required this.positionNotifier,
    required this.currentIndexNotifier,
    required this.offset,
    required this.accentColor,
    required this.onOffsetChanged,
  });

  @override
  State<_LyricsSyncDialog> createState() => _LyricsSyncDialogState();
}

class _LyricsSyncDialogState extends State<_LyricsSyncDialog> {
  late Duration _offset;
  late final TextEditingController _offsetCtrl;
  final FocusNode _offsetFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _offset = widget.offset;
    _offsetCtrl = TextEditingController(text: '${_offset.inMilliseconds}');
    // Al salir del campo: normalizar/clamp el valor tecleado.
    _offsetFocus.addListener(() {
      if (!_offsetFocus.hasFocus) _applyTyped(_offsetCtrl.text);
    });
  }

  @override
  void dispose() {
    _offsetCtrl.dispose();
    _offsetFocus.dispose();
    super.dispose();
  }

  void _adjust(int ms) {
    setState(() => _offset += Duration(milliseconds: ms));
    _offsetCtrl.text = '${_offset.inMilliseconds}';
    widget.onOffsetChanged(_offset);
  }

  /// Aplica el valor tecleado en el campo numérico (clamp ±30s). Si no es
  /// un número válido, restaura el texto al offset vigente.
  void _applyTyped(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) {
      _offsetCtrl.text = '${_offset.inMilliseconds}';
      return;
    }
    final clamped = parsed.clamp(-30000, 30000);
    setState(() => _offset = Duration(milliseconds: clamped));
    _offsetCtrl.text = '$clamped';
    widget.onOffsetChanged(_offset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final lines = widget.lyrics.lines;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
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
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.timer_outlined, color: accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.syncLyricsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Preview de la línea actual + siguiente (en vivo).
                  ValueListenableBuilder<Duration>(
                    valueListenable: widget.positionNotifier,
                    builder: (context, position, _) {
                      final idx = widget.lyrics.getCurrentLineIndex(
                        position - _offset,
                      );
                      final current = (idx != null && idx < lines.length)
                          ? lines[idx].text
                          : '';
                      final next = (idx != null && idx + 1 < lines.length)
                          ? lines[idx + 1].text
                          : '';
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              current.isEmpty ? '...' : current,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (next.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                next,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // Offset actual: campo EDITABLE (se puede teclear el
                  // valor exacto en ms, además de los botones ±).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${l10n.syncCurrent}: ',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(
                        width: 104,
                        child: TextField(
                          controller: _offsetCtrl,
                          focusNode: _offsetFocus,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'-?\d{0,6}'),
                            ),
                          ],
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.bold,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            suffixText: 'ms',
                            suffixStyle: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: theme.colorScheme.outline
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: accent),
                            ),
                          ),
                          onSubmitted: _applyTyped,
                          onChanged: (v) {
                            // Aplicar en vivo solo si lo tecleado es un
                            // número completo (evita saltos al borrar).
                            final parsed = int.tryParse(v.trim());
                            if (parsed != null && v.trim().isNotEmpty) {
                              final clamped = parsed.clamp(-30000, 30000);
                              _offset = Duration(milliseconds: clamped);
                              widget.onOffsetChanged(_offset);
                            }
                          },
                          onEditingComplete: () =>
                              FocusScope.of(context).unfocus(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Botones ±100/±500 ms.
                  Row(
                    children: [
                      _syncButton(theme, '-500', -500, accent),
                      _syncButton(theme, '-100', -100, accent),
                      _syncButton(theme, '+100', 100, accent),
                      _syncButton(theme, '+500', 500, accent),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.done),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncButton(ThemeData theme, String label, int ms, Color accent) {
    final isNegative = ms < 0;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: (isNegative ? Colors.red : Colors.green)
                .withValues(alpha: 0.15),
            foregroundColor: isNegative
                ? Colors.redAccent
                : Colors.greenAccent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: () => _adjust(ms),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// Diálogo de búsqueda manual en LRCLIB: campo de búsqueda, resultados y
/// acciones por resultado (usar / editar la letra con sus timestamps).
class _LyricsSearchDialog extends StatefulWidget {
  final String initialQuery;

  /// Título/artista reales de la pista en reproducción: KPoe y Unison
  /// exigen campos separados y con la query libre no encuentran nada.
  final String? titleHint;
  final String? artistHint;
  final Color? accentColor;

  const _LyricsSearchDialog({
    required this.initialQuery,
    this.titleHint,
    this.artistHint,
    this.accentColor,
  });

  @override
  State<_LyricsSearchDialog> createState() => _LyricsSearchDialogState();
}

class _LyricsSearchDialogState extends State<_LyricsSearchDialog> {
  late final TextEditingController _controller;
  bool _searching = false;
  List<LyricsSearchResult> _results = const [];
  String? _error;
  String _selectedProvider = 'all';

  /// Opciones de proveedor: (valor, etiqueta).
  static const _providerOptions = <(String, String)>[
    ('all', 'Todos (KPoe + Unison + LRCLIB)'),
    ('kpoe', 'KPoe · palabra a palabra'),
    ('unison', 'Unison'),
    ('lrclib', 'LRCLIB · línea'),
  ];

  String _providerLabel(String value) {
    for (final option in _providerOptions) {
      if (option.$1 == value) return option.$2;
    }
    return value;
  }

  /// Selector de proveedor con el mismo estilo que los demás dropdowns de
  /// la app (campo rectangular + showMenu anclado, items full-bleed).
  Widget _buildProviderSelector(ThemeData theme) {
    return Builder(
      builder: (fieldContext) => InkWell(
        borderRadius: BorderRadius.circular(14),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onTap: () => _openProviderMenu(fieldContext),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color:
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _providerLabel(_selectedProvider),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: theme.colorScheme.primary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openProviderMenu(BuildContext fieldContext) async {
    final box = fieldContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(fieldContext).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 260, maxHeight: 380),
      clipBehavior: Clip.antiAlias,
      items: [
        for (final option in _providerOptions)
          PopupMenuItem<String>(value: option.$1, child: Text(option.$2)),
      ],
    );
    if (selected == null || !mounted || selected == _selectedProvider) return;
    setState(() => _selectedProvider = selected);
    // Re-buscar con el proveedor recién elegido si ya había consulta.
    if (_controller.text.trim().isNotEmpty) {
      _performSearch(_controller.text);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final res = await context.read<LyricsService>().searchLyrics(
            q,
            provider: _selectedProvider,
            titleHint: widget.titleHint,
            artistHint: widget.artistHint,
          );
      if (!mounted) return;
      setState(() {
        _results = res;
        _searching = false;
        _error = res.isEmpty
            ? AppLocalizations.of(context).lyricsSearchNoResults
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = AppLocalizations.of(context).lyricsSearchError;
      });
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
        width: 520,
        constraints: const BoxConstraints(maxHeight: 560),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
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
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.lyrics_outlined,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.searchLyrics,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: TextField(
                controller: _controller,
                onSubmitted: _performSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l10n.lyricsSearchHint,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.search, size: 18),
                          onPressed: () => _performSearch(_controller.text),
                        ),
                  filled: true,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.source, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text('Proveedor:', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const Spacer(),
                  _buildProviderSelector(theme),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: _buildResults(theme, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme, AppLocalizations l10n) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('')),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final r = _results[i];
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            dense: true,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.lyrics_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    r.trackName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (r.provider.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      r.provider,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              r.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Editar la letra (texto con sus timestamps) antes de usar.
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: l10n.editLyrics,
                  onPressed: () => _openEditor(r),
                ),
                IconButton(
                  icon: const Icon(Icons.check, size: 18),
                  tooltip: l10n.useLyrics,
                  onPressed: () => Navigator.pop(context, r),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Abre el editor de la letra: un campo multilínea con el LRC (texto +
  /// timestamps) editable. Al guardar, se devuelve el resultado modificado.
  void _openEditor(LyricsSearchResult result) {
    final controller = TextEditingController(
      text: result.syncedLyrics.trim().isNotEmpty
          ? result.syncedLyrics
          : _plainToLrc(result.plainLyrics),
    );
    showDialog<LyricsSearchResult>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final l10n = AppLocalizations.of(ctx);
        return AlertDialog(
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          title: Text(l10n.editLyrics),
          content: SizedBox(
            width: 480,
            height: 320,
            child: TextField(
              controller: controller,
              maxLines: null,
              expands: true,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              decoration: InputDecoration(
                hintText: l10n.editLyricsHint,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                if (raw.isEmpty) return;
                Navigator.pop(
                  ctx,
                  LyricsSearchResult(
                    id: result.id,
                    trackName: result.trackName,
                    artistName: result.artistName,
                    albumName: result.albumName,
                    duration: result.duration,
                    synced: true,
                    plainLyrics: '',
                    syncedLyrics: raw,
                  ),
                );
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ).then((edited) {
      if (edited != null && mounted) {
        Navigator.pop(context, edited);
      }
    });
  }

  /// Convierte texto plano a LRC básico (cada línea con timestamp 0).
  String _plainToLrc(String plain) {
    return plain
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => '[00:00.00] ${l.trim()}')
        .join('\n');
  }
}
