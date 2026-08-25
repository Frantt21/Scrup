import 'dart:async';
import 'dart:io' show File, Platform, Process;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/lyrics_search_result.dart';
import '../../core/track.dart';
import '../../core/synced_lyrics.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';
import '../../services/settings_store.dart';
import '../../services/silence_skip_service.dart';
import '../theme_controller.dart';
import '../widgets/cover_image.dart';
import '../widgets/lyrics_display.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;

/// Vista de letras sincronizadas: contenedor glass (igual que Inicio/Buscar)
/// montado en el IndexedStack del AppShell. Muestra las lyrics de la pista
/// en reproducción con auto-scroll, karaoke sweep, tap-to-seek, búsqueda
/// manual y sincronización manual (port de forawn_mobile).
class LyricsView extends StatefulWidget {
  /// Modo EMBEBIDO (pantalla completa): sin margen, sombra ni fondo plano —
  /// las letras flotan sobre el fondo que las rodea. Por defecto `false`
  /// (contenedor glass habitual dentro del shell).
  final bool embedded;

  const LyricsView({super.key, this.embedded = false});

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  Track? _track;
  SyncedLyrics? _lyrics;

  /// `true` mientras se busca en LRCLIB (spinner en el estado vacío).
  bool _loading = false;

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

  /// Desfase de sincronización de la pista: LA ÚNICA RAÍZ que se aplica
  /// (se resta a la posición para el índice y el sweep; el tap-to-seek lo
  /// suma). Nace del ajuste manual y absorbe — una sola vez, al persistirlo
  /// en [_loadTrackOffset]/[_absorbAutoIntro] — el intro no musical que
  /// reporta SponsorBlock: nada se suma por encima en tiempo de ejecución.
  Duration _lyricsOffset = Duration.zero;
  late final SilenceSkipService _silenceSkip;

  /// Modo karaoke (sweep palabra por palabra): se refleja en el widget de
  /// lyrics y se persiste vía el SettingsStore.
  bool _sweepEnabled = false;

  /// Modo embebido (fullscreen): acciones de la cabecera solo con hover.
  bool _actionsHovered = false;

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

    // Escucha de SponsorBlock: si llegan datos nuevos para la pista actual,
    // el intro se absorbe en la raíz persistida (ver [_absorbAutoIntro]).
    _silenceSkip = context.read<SilenceSkipService>();
    _silenceSkip.addListener(_onSilenceInfoChanged);

    _trackSub = player.currentTrack.listen((t) {
      if (!mounted) return;
      setState(() {
        _track = t;
        _lyrics = null;
        _lyricsOffset = Duration.zero;
      });
      // El offset es POR PISTA: cargar el ajuste guardado de esta canción y,
      // si nunca se tocó, absorber el intro de SponsorBlock en la raíz
      // (cambiar de pista o de fuente de letra no lo pierde).
      unawaited(_loadTrackOffset(t).then((_) => _absorbAutoIntro(t)));
      _fetchLyrics(t);
    });
    _positionSub = player.position.listen((p) {
      if (!mounted) return;
      // Nueva base de extrapolación (y snap para pausa/seek).
      _smoothBasePosition = p;
      _smoothBaseAt = DateTime.now();
      if (!_playing) _position.value = p;
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

  /// SponsorBlock contestó con datos nuevos: si la pista actual nunca tuvo
  /// offset propio, su intro no musical se absorbe en la raíz persistida
  /// (p.ej. la consulta llegó cuando la letra ya estaba en pantalla).
  void _onSilenceInfoChanged() {
    if (!mounted) return;
    unawaited(_absorbAutoIntro(_track));
  }

  /// Carga el offset POR PISTA y lo aplica si la pista sigue siendo la
  /// actual (una respuesta tardía no pisa el offset de otra canción).
  Future<void> _loadTrackOffset(Track? track) async {
    if (track == null) return;
    try {
      final offset = await context.read<SettingsStore>().loadLyricsOffsetFor(
        track.id,
      );
      if (!mounted || _track?.id != track.id) return;
      setState(() => _lyricsOffset = offset);
    } catch (_) {}
  }

  /// Absorbe el intro no musical que SponsorBlock reporta para [track] en
  /// LA MISMA RAÍZ del offset manual — una sola vez, y solo si la pista
  /// nunca tuvo entrada propia: el valor queda persistido, visible y
  /// editable en el diálogo de sincronización como cualquier otro; nada se
  /// suma por encima en tiempo de ejecución (ni «hardcodeado» ni volátil:
  /// si mañana SponsorBlock no contesta, el ajuste sigue ahí).
  ///
  /// Si el usuario YA ajustó esa canción a mano, no se toca: su valor manda.
  Future<void> _absorbAutoIntro(Track? track) async {
    if (track == null) return;
    final intro = _silenceSkip.introEndFor(track.id);
    if (intro == null || intro <= Duration.zero) return;
    final store = context.read<SettingsStore>();
    try {
      if (await store.hasLyricsOffsetFor(track.id)) return;
      await store.saveLyricsOffsetFor(track.id, intro);
    } catch (_) {
      return;
    }
    if (!mounted || _track?.id != track.id) return;
    setState(() => _lyricsOffset = intro);
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _silenceSkip.removeListener(_onSilenceInfoChanged);
    _smoothingTick.dispose();
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
      final lyrics = await context.read<LyricsService>().fetchLyrics(
        track.title,
        track.artist,
      );
      if (!mounted || token != _fetchToken) return;
      setState(() {
        _lyrics = lyrics;
        _loading = false;
      });
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
    await context.read<LyricsService>().saveManualLyrics(
      track.title,
      track.artist,
      sourceLrc ?? lyrics.toLRC(),
    );
    if (!mounted) return;
    setState(() {
      _lyrics = lyrics;
      // El offset por pista se CONSERVA: cambiar la fuente de la letra no
      // debe perder la sincronización que el usuario ya ajustó.
    });
  }

  /// Tap en una línea: seek a ese timestamp (respetando el offset total).
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

  /// Future del audio path CACHEADO por pista (identidad). Un FutureBuilder
  /// se resetea a `ConnectionState.waiting` (data: null) cada vez que cambia
  /// la INSTANCIA del future — y aquí se reconstruye en cada rebuild, p. ej.
  /// al alternar fullscreen↔normal (cambia `embedded`). Ese parpadeo
  /// null→path hacía que LyricsDisplay creyera que cambió la pista y
  /// reiniciara el scroll al inicio. Con el future cacheado, el snapshot se
  /// mantiene estable entre rebuilds.
  Track? _audioPathTrack;
  Future<String?>? _audioPathFuture;

  Future<String?> _audioPathFutureFor(Track track) {
    if (!identical(_audioPathTrack, track)) {
      _audioPathTrack = track;
      _audioPathFuture = _audioPathOf(track);
    }
    return _audioPathFuture!;
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
  /// forawn_mobile): muestra la línea actual/siguiente y ajusta el offset —
  /// el MISMO valor que se aplica y persiste: una sola raíz.
  Future<void> _showSyncDialog() async {
    final lyrics = _lyrics;
    if (lyrics == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _LyricsSyncDialog(
        lyrics: lyrics,
        positionNotifier: _position,
        offset: _lyricsOffset,
        accentColor: context.read<ThemeController>().accentColor,
        onOffsetChanged: (offset) {
          // setState OBLIGATORIO: la pantalla consume widget.lyricsOffset
          // para su índice activo — sin rebuild el cambio no se ve en vivo.
          setState(() => _lyricsOffset = offset);
          // Persistir POR PISTA: cada canción recuerda su propio ajuste.
          final track = _track;
          if (track != null) {
            context.read<SettingsStore>().saveLyricsOffsetFor(track.id, offset);
          }
        },
      ),
    );
  }

  /// Diálogo para compartir la letra: ventana de tres líneas (anterior,
  /// actual, siguiente) navegable, texto editable y salidas (copiar, PNG
  /// o intents web).
  void _showShareDialog() {
    final lyrics = _lyrics;
    final track = _track;
    if (lyrics == null || track == null) return;
    // Misma fórmula que la pantalla: posición menos el offset raíz.
    final idx = lyrics.getCurrentLineIndex(_position.value - _lyricsOffset);
    showDialog<void>(
      context: context,
      builder: (ctx) => _LyricsShareDialog(
        lyrics: lyrics,
        initialIndex: idx ?? 0,
        trackTitle: track.title,
        artist: track.artist,
        artworkUrl: track.thumbnailUrl,
        accentColor: context.read<ThemeController>().accentColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // El acento del artwork de la pista tiñe las letras.
    final accent = context.watch<ThemeController>().accentColor;

    final embedded = widget.embedded;
    return Container(
      margin: embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 12, 12, kPlayerClearance),
      decoration: embedded
          ? null
          : BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
      child: embedded
          ? _body(theme, l10n, accent, embedded)
          : ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // Fondo plano (sin gradiente translúcido): las letras del
                  // color de la canción se leen sobre él.
                  color: theme.colorScheme.surfaceContainer,
                ),
                child: _body(theme, l10n, accent, embedded),
              ),
            ),
    );
  }

  /// Cuerpo común de la vista (header + listado de letras), compartido por
  /// el modo normal (con contenedor) y el embebido (fullscreen).
  Widget _body(
    ThemeData theme,
    AppLocalizations l10n,
    Color? accent,
    bool embedded,
  ) {
    final header = Padding(
      // Embebido: header mínimo (solo botones hover) → menos alto.
      padding: embedded
          ? const EdgeInsets.fromLTRB(4, 6, 4, 0)
          : const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          // Artwork a la altura de ambas filas (título + artista).
          // En modo embebido (fullscreen) se omite: el artwork y
          // el título ya viven en la cabecera del modo.
          if (!embedded && _track != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 46,
                height: 46,
                child: CoverImage(
                  source: _track!.thumbnailUrl,
                  fit: BoxFit.cover,
                  fallback: Icon(
                    Icons.music_note_rounded,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          // En embebido el título/artista se ocultan: los botones
          // se alinean a la derecha con un Spacer.
          if (!embedded)
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
            )
          else
            const Spacer(),
          // Acciones (karaoke/sync/buscar/compartir): sueltas y
          // SOLO visibles al hover en modo embebido; siempre
          // visibles en el modo normal.
          MouseRegion(
            onEnter: (_) {
              if (embedded) setState(() => _actionsHovered = true);
            },
            onExit: (_) {
              if (embedded) setState(() => _actionsHovered = false);
            },
            child: IgnorePointer(
              ignoring: embedded && !_actionsHovered,
              child: AnimatedOpacity(
                opacity: !embedded || _actionsHovered ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Modo karaoke (sweep palabra por palabra).
                    IconButton(
                      icon: Icon(
                        Icons.graphic_eq_rounded,
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
                      icon: const Icon(Icons.timer_rounded),
                      tooltip: l10n.syncLyricsTitle,
                      onPressed: _lyrics == null ? null : _showSyncDialog,
                    ),
                    // Búsqueda manual en LRCLIB.
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      tooltip: l10n.searchLyrics,
                      onPressed: _track == null ? null : _showSearchDialog,
                    ),
                    // Compartir la línea actual (imagen o web).
                    IconButton(
                      icon: const Icon(Icons.share_rounded),
                      tooltip: l10n.shareLyrics,
                      onPressed: _lyrics == null ? null : _showShareDialog,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // En embebido el header NO ocupa layout: flota sobre la esquina
    // superior derecha (hover) y las letras empiezan en el MISMO top que
    // el artwork.
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!embedded) header,
        Expanded(child: _buildBody(theme, l10n, accent, embedded)),
      ],
    );
    if (!embedded) return content;
    return Stack(
      children: [
        content,
        Positioned(top: 0, right: 0, child: header),
      ],
    );
  }

  Widget _buildBody(
    ThemeData theme,
    AppLocalizations l10n,
    Color? accent,
    bool embedded,
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
                Icons.lyrics_rounded,
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
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(l10n.searchLyrics),
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<String?>(
      future: _audioPathFutureFor(track),
      builder: (context, snapshot) {
        return LyricsDisplay(
          lyrics: lyrics,
          positionNotifier: _position,
          durationNotifier: _duration,
          audioPath: snapshot.data,
          lyricsOffset: _lyricsOffset,
          onTap: _onLineTap,
          accentColor: accent,
          sweepEnabled: _sweepEnabled,
          embedded: embedded,
        );
      },
    );
  }
}

/// Diálogo de sincronización manual: preview de la línea actual/siguiente y
/// botones para desplazar el offset ±100/±500 ms (port de forawn_mobile).
/// El campo muestra y edita EL offset que de verdad se aplica: la raíz única
/// persistida por pista (el intro automático de SponsorBlock ya vive dentro).
class _LyricsSyncDialog extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueListenable<Duration> positionNotifier;

  /// Offset vigente de la pista (editable aquí).
  final Duration offset;
  final Color? accentColor;
  final ValueChanged<Duration> onOffsetChanged;

  const _LyricsSyncDialog({
    required this.lyrics,
    required this.positionNotifier,
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
                  Icon(Icons.timer_rounded, color: accent, size: 20),
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
                    icon: const Icon(Icons.close_rounded, size: 18),
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
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.35,
                                ),
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
            foregroundColor: isNegative ? Colors.redAccent : Colors.greenAccent,
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
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.35,
            ),
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
                    Icons.lyrics_rounded,
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
                    icon: const Icon(Icons.close_rounded, size: 18),
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
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
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
                          icon: const Icon(Icons.search_rounded, size: 18),
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
                  Icon(
                    Icons.source_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Proveedor:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  _buildProviderSelector(theme),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Flexible(child: _buildResults(theme, l10n)),
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
      return const SizedBox(height: 120, child: Center(child: Text('')));
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
                Icons.lyrics_rounded,
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
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  tooltip: l10n.editLyrics,
                  onPressed: () => _openEditor(r),
                ),
                IconButton(
                  icon: const Icon(Icons.check_rounded, size: 18),
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

/// Diálogo de compartir letra: tarjeta prevista (la MISMA que se exporta:
/// PNG vía RepaintBoundary o portapapeles), navegación de la ventana de
/// tres líneas (anterior / actual / siguiente) con el MISMO estilo de las
/// letras en pantalla, y salidas: copiar imagen, guardar PNG o abrir una
/// web (X, WhatsApp, Telegram, email) con la imagen ya en el portapapeles
/// para pegarla ahí mismo.
class _LyricsShareDialog extends StatefulWidget {
  final SyncedLyrics lyrics;
  final int initialIndex;
  final String trackTitle;
  final String artist;
  final String? artworkUrl;
  final Color? accentColor;

  const _LyricsShareDialog({
    required this.lyrics,
    required this.initialIndex,
    required this.trackTitle,
    required this.artist,
    this.artworkUrl,
    this.accentColor,
  });

  @override
  State<_LyricsShareDialog> createState() => _LyricsShareDialogState();
}

class _LyricsShareDialogState extends State<_LyricsShareDialog> {
  late int _center;
  final GlobalKey _captureKey = GlobalKey();

  /// Mismo tratamiento que la pantalla: acento «legible» para la línea
  /// activa y el mismo color al 30% para las inactivas.
  static Color _readableAccent(Color c) =>
      c.computeLuminance() < 0.35 ? Color.lerp(c, Colors.white, 0.5)! : c;

  int get _lineCount => widget.lyrics.lines.length;

  LyricLine? _lineAt(int i) =>
      (i >= 0 && i < _lineCount) ? widget.lyrics.lines[i] : null;

  LyricLine get _current {
    final i = _center.clamp(0, _lineCount - 1);
    return widget.lyrics.lines[i];
  }

  @override
  void initState() {
    super.initState();
    _center = widget.initialIndex.clamp(0, _lineCount - 1);
    // Precargar el artwork para que el PNG no salga con el fallback.
    final src = widget.artworkUrl;
    if (src != null && src.isNotEmpty) {
      final ImageProvider provider = CoverImage.isLocalPath(src)
          ? FileImage(File(src))
          : NetworkImage(src);
      precacheImage(provider, context).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _move(int delta) {
    final next = (_center + delta).clamp(0, _lineCount - 1);
    if (next == _center) return;
    setState(() => _center = next);
  }

  /// Captura la tarjeta tal como se ve (pixelRatio 3 ⇒ nítida).
  Future<Uint8List?> _captureBytes() async {
    final boundary = _captureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
  }

  /// Copia el PNG al portapapeles del sistema sin dependencias extra:
  /// escribe un temporal y delega en wl-copy (Wayland), xclip (X11) o
  /// PowerShell (Windows).
  Future<bool> _pngToClipboard(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/scrup-share-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes);
    try {
      if (Platform.isWindows) {
        final quoted = file.path.replaceAll("'", "''");
        final res = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "Set-Clipboard -Path '$quoted'",
        ]);
        return res.exitCode == 0;
      }
      final escaped = file.path.replaceAll("'", r"'\''");
      var res = await Process.run('sh', [
        '-c',
        "wl-copy -t image/png < '$escaped'",
      ]);
      if (res.exitCode != 0) {
        res = await Process.run('sh', [
          '-c',
          'xclip -selection clipboard -t image/png -i \'$escaped\'',
        ]);
      }
      return res.exitCode == 0;
    } catch (e) {
      debugPrint('[Scrup] Share: portapapeles falló: $e');
      return false;
    } finally {
      unawaited(file.delete().catchError((_) => file));
    }
  }

  Future<void> _copyImage() async {
    final l10n = AppLocalizations.of(context);
    final bytes = await _captureBytes();
    if (bytes == null) return;
    final ok = await _pngToClipboard(bytes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.imageCopied : l10n.copyText)),
    );
  }

  /// Exporta la tarjeta prevista como archivo PNG (selector de guardado).
  Future<void> _saveImage() async {
    final l10n = AppLocalizations.of(context);
    try {
      final bytes = await _captureBytes();
      if (bytes == null) return;
      final safe = widget.trackTitle.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final suggested = '${safe.isEmpty ? 'lyrics' : safe} - scrup.png';
      final location = await getSaveLocation(
        suggestedName: suggested,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG', extensions: ['png']),
        ],
      );
      if (location == null) return;
      await XFile.fromData(
        bytes,
        mimeType: 'image/png',
        name: 'lyrics.png',
      ).saveTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.imageSaved)));
    } catch (e) {
      debugPrint('[Scrup] Share: error guardando imagen: $e');
    }
  }

  /// Abre la web destino CON la imagen ya copiada en el portapapeles:
  /// compartir es colocar la imagen, no un texto.
  Future<void> _openShareTarget(String site, Uri uri) async {
    final l10n = AppLocalizations.of(context);
    final bytes = await _captureBytes();
    var copied = false;
    if (bytes != null) copied = await _pngToClipboard(bytes);
    if (!mounted) return;
    if (copied) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.imageCopied)));
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Scrup] Share: no se pudo abrir $site: $e');
    }
  }

  List<Widget> _webActions(AppLocalizations l10n, ThemeData theme) {
    final targets = <(String, IconData, Uri)>[
      (
        'X',
        Icons.alternate_email_rounded,
        Uri.https('twitter.com', '/intent/tweet'),
      ),
      ('WhatsApp', Icons.chat_bubble_rounded, Uri.https('wa.me', '/')),
      ('Telegram', Icons.send_rounded, Uri.https('t.me', '/share/url')),
      (
        'Email',
        Icons.mail_rounded,
        Uri(scheme: 'mailto', queryParameters: {'subject': widget.trackTitle}),
      ),
    ];
    return [
      for (final (site, icon, uri) in targets)
        IconButton(
          icon: Icon(icon),
          tooltip: l10n.shareOnSite(site),
          color: theme.colorScheme.onSurfaceVariant,
          onPressed: () => _openShareTarget(site, uri),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final prev = _lineAt(_center - 1);
    final next = _lineAt(_center + 1);

    return Dialog(
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.shareLyrics,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                // Tarjeta compartible (WYSIWYG: esto ES el PNG).
                Center(child: _buildCard(theme, accent, prev, next)),
                const SizedBox(height: 12),
                // Navegación de la línea central.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      onPressed: _center <= 0 ? null : () => _move(-1),
                    ),
                    Text(
                      l10n.lineOfTotal(_center + 1, _lineCount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: _center >= _lineCount - 1
                          ? null
                          : () => _move(1),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.image_rounded, size: 18),
                      label: Text(l10n.saveAsImage),
                      onPressed: _saveImage,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: Text(l10n.copyText),
                      onPressed: _copyImage,
                    ),
                    ..._webActions(l10n, theme),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Estilo EXACTO de las letras en pantalla (lyrics_display): 38 px bold,
  /// height 1.3, Roboto; activa en acento legible, inactivas al 30%.
  TextStyle _lyricStyle(Color color) => const TextStyle(
    fontSize: 38,
    fontWeight: FontWeight.bold,
    height: 1.3,
    fontFamily: 'Roboto',
  ).copyWith(color: color);

  Widget _buildCard(
    ThemeData theme,
    Color accent,
    LyricLine? prev,
    LyricLine? next,
  ) {
    const bg = Color(0xFF15151C);
    final readable = _readableAccent(accent);
    final activeColor = readable;
    final inactiveColor = readable.withValues(alpha: 0.3);
    return RepaintBoundary(
      key: _captureKey,
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Color.alphaBlend(readable.withValues(alpha: .14), bg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (prev != null) ...[
              Text(
                prev.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _lyricStyle(inactiveColor),
              ),
              const SizedBox(height: 16),
            ],
            Text(_current.text, style: _lyricStyle(activeColor)),
            if (next != null) ...[
              const SizedBox(height: 16),
              Text(
                next.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _lyricStyle(inactiveColor),
              ),
            ],
            const SizedBox(height: 26),
            Row(
              children: [
                // Mismo patrón que el header de letras: artwork 1:1 a la
                // izquierda y columna título/artista al lado (en miniatura).
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CoverImage(
                      source: widget.artworkUrl,
                      fit: BoxFit.cover,
                      fallback: ColoredBox(
                        color: Colors.white.withValues(alpha: .08),
                        child: const Icon(
                          Icons.music_note_rounded,
                          size: 20,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.trackTitle.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Logo de la app donde antes decía «Scrup».
                Opacity(
                  opacity: 0.55,
                  child: Image.asset(
                    'assets/app-logo.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (_, _, _) => const Text('Scrup'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
