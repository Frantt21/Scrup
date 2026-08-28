import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../core/binaries.dart';
import '../data/database.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/player_service.dart';
import '../services/settings_store.dart';
import 'views/home_view.dart';
import 'views/lyrics_view.dart';
import 'views/playlist_detail_view.dart';
import 'views/search_view.dart';
import 'views/settings_view.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/fullscreen_player_view.dart';
import 'widgets/player_bar.dart';
import 'widgets/playlists_sidebar.dart';
import 'widgets/queue_panel.dart';
import 'widgets/scrup_toasts.dart';

/// Contenedor principal de la app: title bar personalizado, contenedor
/// lateral con las playlists (glass), el inicio con búsqueda + recientes y
/// el reproductor flotante.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  StreamSubscription<String>? _errorSub;

  /// Playlist abierta en detalle (se renderiza en el espacio de contenido,
  /// sin abrir rutas).
  Playlist? _openPlaylist;

  /// `true` mientras la pantalla de configuración esté abierta.
  bool _showSettings = false;

  /// Veces que se ha abierto la configuración: se usa como key para recrear
  /// la vista cada vez y que las estadísticas del caché se recalculen al
  /// abrir (el IndexedStack mantiene vivos a todos los hijos, así que el
  /// initState solo corre al arrancar si no se fuerza un State nuevo).
  int _settingsOpenCount = 0;

  /// Consulta de búsqueda lanzada desde el inicio: el HomeView la escribe y
  /// la SearchView la ejecuta al cambiar de vista.
  final ValueNotifier<String?> _searchRequest = ValueNotifier<String?>(null);

  /// `true` mientras el panel de la cola esté abierto (se desliza desde la
  /// derecha empujando el contenido).
  bool _queueOpen = false;

  /// El usuario ya alternó la cola: evita que la carga asíncrona de la
  /// preferencia sobrescriba su elección (carrera de arranque).
  bool _queueUserToggled = false;

  /// `true` mientras la vista de lyrics esté abierta (se monta en el
  /// IndexedStack como Inicio/Búsqueda).
  bool _showLyrics = false;

  /// Modo pantalla completa (F11 para alternar, Esc para salir): oculta la
  /// title bar y monta el reproductor dedicado encima de TODO. PUNTO DE
  /// PARTIDA del diseño visual completo definido con el usuario.
  bool _fullscreen = false;

  /// El overlay fullscreen permanece montado mientras anima la salida (el
  /// flag lógico [_fullscreen] ya está en false: F11/Esc no re-disparan).
  bool _showFsOverlay = false;

  /// Key global para reparentar LyricsView entre el IndexedStack normal y
  /// el panel derecho del modo fullscreen SIN recrear su State: cero
  /// re-fetch de letras y un solo ticker de sweep.
  final GlobalKey _fsLyricsKey = GlobalKey();

  void _onBinaryDownloadStatus() {
    final status = Binaries.downloadStatus.value;
    if (status == null || !mounted) return;
    showScrupToast(
      status.label,
      kind: ScrupToastKind.info,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void initState() {
    super.initState();
    // Errores de reproducción globales (URL expirada, 403, etc.)
    _errorSub = context.read<PlayerService>().errors.listen((message) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showScrupToast(
        l10n.playbackErrorWithDetails(message),
        kind: ScrupToastKind.error,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final yt = Binaries.ytdlpPath;
      final ff = Binaries.ffmpegPath;
      if (yt == null || ff == null) {
        if (!mounted) return;
        final initial =
            'Descargando binarios de audio… Esto puede tardar unos segundos.';
        showScrupToast(
          initial,
          kind: ScrupToastKind.info,
          duration: const Duration(seconds: 6),
        );

        Binaries.downloadStatus.addListener(_onBinaryDownloadStatus);

        final ok = await Binaries.ensureSidecarsPresent();
        if (mounted) {
          Binaries.downloadStatus.removeListener(_onBinaryDownloadStatus);
          Binaries.downloadStatus.value = null;
        }

        if (!mounted) return;
        if (!ok) {
          final ytAfter = Binaries.ytdlpPath;
          final ffAfter = Binaries.ffmpegPath;
          if (ytAfter == null || ffAfter == null) {
            showScrupToast(
              'Faltan binarios de audio: ${[if (ytAfter == null) 'yt-dlp', if (ffAfter == null) 'ffmpeg'].join(', ')}. Ejecuta la descarga o instala curl/PowerShell.',
              kind: ScrupToastKind.error,
              duration: const Duration(seconds: 8),
            );
          }
        }
      }
    });
    // Restaurar el estado de la cola (abierta/cerrada) de la última sesión.
    unawaited(_loadQueuePref());
    // Atajos del modo fullscreen (F11 alterna, Esc sale).
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  /// Atajos globales de teclado. Devuelve true solo cuando consume la tecla.
  ///
  /// No se disparan cuando el foco está en un campo de texto (TextField /
  /// SearchBar) para que el usuario pueda escribir sin conflictos.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // No disparar atajos si hay un campo de texto enfocado.
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null) {
      final ctx = focus.context;
      if (ctx != null &&
          (ctx.findAncestorWidgetOfExactType<EditableText>() != null)) {
        return false;
      }
    }

    final key = event.logicalKey;
    final player = context.read<PlayerService>();

    // F11: fullscreen
    if (key == LogicalKeyboardKey.f11) {
      _setFullscreen(!_fullscreen);
      return true;
    }
    // Esc: salir de fullscreen o cerrar panel abierto
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _setFullscreen(false);
        return true;
      }
      if (_showSettings) {
        _closeSettings();
        return true;
      }
      if (_showLyrics) {
        _closeLyrics();
        return true;
      }
      if (_queueOpen) {
        setState(() => _queueOpen = false);
        return true;
      }
      if (_openPlaylist != null) {
        _selectPlaylist(null);
        return true;
      }
    }

    // ── Reproducción ──────────────────────────────────────────────
    // Space: play / pausa
    if (key == LogicalKeyboardKey.space) {
      player.togglePlayPause();
      return true;
    }
    // N: siguiente canción
    if (key == LogicalKeyboardKey.keyN) {
      player.next();
      return true;
    }
    // P: canción anterior
    if (key == LogicalKeyboardKey.keyP) {
      player.previous();
      return true;
    }
    // →: adelantar 10s
    if (key == LogicalKeyboardKey.arrowRight) {
      final pos = player.positionValue;
      final dur = player.durationValue;
      final target = pos + const Duration(seconds: 10);
      player.seek(dur != null && target > dur ? dur : target);
      return true;
    }
    // ←: retroceder 10s
    if (key == LogicalKeyboardKey.arrowLeft) {
      final pos = player.positionValue;
      final target = pos - const Duration(seconds: 10);
      player.seek(target.isNegative ? Duration.zero : target);
      return true;
    }
    // ↑: subir volumen 5%
    if (key == LogicalKeyboardKey.arrowUp) {
      player.setVolume((player.volume.value + 0.05).clamp(0.0, 1.0));
      return true;
    }
    // ↓: bajar volumen 5%
    if (key == LogicalKeyboardKey.arrowDown) {
      player.setVolume((player.volume.value - 0.05).clamp(0.0, 1.0));
      return true;
    }
    // M: mute / unmute
    if (key == LogicalKeyboardKey.keyM) {
      player.toggleMute();
      return true;
    }

    // ── Navegación ────────────────────────────────────────────────
    // L: abrir/cerrar lyrics
    if (key == LogicalKeyboardKey.keyL) {
      setState(() => _showLyrics = !_showLyrics);
      return true;
    }
    // Q: abrir/cerrar cola
    if (key == LogicalKeyboardKey.keyQ) {
      setState(() => _queueOpen = !_queueOpen);
      return true;
    }
    // , (comma): abrir/cerrar settings
    if (key == LogicalKeyboardKey.comma) {
      if (_showSettings) {
        _closeSettings();
      } else {
        _openSettings();
      }
      return true;
    }

    // ── Modos ─────────────────────────────────────────────────────
    // S: toggle shuffle
    if (key == LogicalKeyboardKey.keyS) {
      player.toggleShuffle();
      return true;
    }
    // R: toggle repeat (off → all → one)
    if (key == LogicalKeyboardKey.keyR) {
      player.toggleRepeat();
      return true;
    }
    // D: toggle radio
    if (key == LogicalKeyboardKey.keyD) {
      player.toggleRadio();
      return true;
    }

    // ── Favoritos ─────────────────────────────────────────────────
    // F: agregar/quitar de favoritos
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFavorite();
      return true;
    }

    return false;
  }

  /// Alterna la canción actual en la playlist de Favoritos (mismo
  /// comportamiento que el corazón en el player bar).
  Future<void> _toggleFavorite() async {
    final player = context.read<PlayerService>();
    final track = player.currentTrackValue;
    if (track == null) return;
    final db = context.read<AppDatabase>();
    final id = await db.ensureFavoritesPlaylist();
    // Consulta puntual (no stream) para saber si ya está guardada.
    final query = db.select(db.playlistTracks)
      ..where(
        (pt) => pt.playlistId.equals(id) & pt.trackId.equals(track.id),
      );
    final rows = await query.get();
    if (rows.isNotEmpty) {
      await db.removeFromPlaylist(id, track.id);
    } else {
      await db.addToPlaylist(id, track);
    }
  }

  /// Entra/sale de pantalla completa: oculta la title bar, monta el
  /// reproductor dedicado y pide al WM el modo nativo. La salida animada la
  /// gestiona el overlay (reverse → onExited → desmontar).
  Future<void> _setFullscreen(bool on) async {
    if (_fullscreen == on) return;
    setState(() {
      _fullscreen = on;
      if (on) _showFsOverlay = true;
    });
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {
      // Sin WM cooperativo el overlay sigue siendo usable.
    }
  }

  /// Restaura el panel de la cola al estado en que quedó la última sesión
  /// (best-effort: si falla, arranca cerrado).
  Future<void> _loadQueuePref() async {
    try {
      final saved = await context.read<SettingsStore>().loadQueueOpen();
      if (!mounted || saved == null || _queueUserToggled) return;
      setState(() => _queueOpen = saved);
    } catch (_) {
      // La preferencia nunca debe impedir el arranque.
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    Binaries.downloadStatus.removeListener(_onBinaryDownloadStatus);
    _searchRequest.dispose();
    super.dispose();
  }

  /// Lanza una búsqueda desde el inicio: cambia a la SearchView y le pasa la
  /// consulta.
  void _submitSearch(String query) {
    _searchRequest.value = query;
    setState(() => _selectedIndex = 1);
  }

  /// Vuelve al inicio desde la SearchView.
  void _backToHome() {
    setState(() => _selectedIndex = 0);
  }

  /// Abre la vista de lyrics como capa sobre la zona actual: NO cierra
  /// playlist/settings (el IndexedStack prioriza el índice de letras y al
  /// cerrar se recupera exactamente donde estaba el usuario).
  void _openLyrics() {
    setState(() => _showLyrics = true);
  }

  /// Cierra la vista de lyrics y vuelve a la zona que hubiera debajo.
  void _closeLyrics() {
    setState(() => _showLyrics = false);
  }

  void _selectPlaylist(Playlist? playlist) {
    setState(() {
      _openPlaylist = playlist;
      _showSettings = false;
      _showLyrics = false;
    });
  }

  void _openSettings() {
    setState(() {
      _showSettings = true;
      _openPlaylist = null;
      _showLyrics = false;
      _settingsOpenCount++;
    });
  }

  void _closeSettings() {
    setState(() => _showSettings = false);
  }

  /// Actualiza la playlist abierta tras una edición (p. ej. renombrada) para
  /// que la title bar muestre el nombre nuevo.
  void _onPlaylistUpdated(Playlist playlist) {
    if (_openPlaylist?.id != playlist.id) return;
    setState(() => _openPlaylist = playlist);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final openPlaylist = _openPlaylist;
    // Barra superior: el título de la zona ocupa EL MISMO sitio que el
    // título de la app ("Scrup"), sin nada delante que lo desplace. Al estar
    // dentro de una zona (playlist/configuración) se muestran junto al
    // título las acciones de navegación: inicio (home) y búsqueda. El
    // engranaje de configuración vive a la derecha. Lo usa la CustomTitleBar
    // en las 3 plataformas (la title bar personalizada sustituye a la nativa
    // en todas; en macOS los botones de ventana los conserva el sistema, en
    // Windows/Linux los dibuja la barra).
    final inZone = _showSettings || openPlaylist != null;
    final barTitle = _showSettings
        ? l10n.settings
        : (openPlaylist?.name ?? 'Scrup');
    final List<Widget> barActions = [
      if (inZone) ...[
        IconButton(
          icon: const Icon(Icons.home_rounded),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          tooltip: l10n.backToHome,
          onPressed: () => setState(() {
            _showSettings = false;
            _openPlaylist = null;
            _showLyrics = false;
            _selectedIndex = 0;
          }),
        ),
        IconButton(
          icon: const Icon(Icons.search_rounded),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          tooltip: l10n.searchTitle,
          onPressed: () => setState(() {
            _showSettings = false;
            _openPlaylist = null;
            _showLyrics = false;
            _selectedIndex = 1;
          }),
        ),
      ],
    ];
    final Widget barTrailing = IconButton(
      icon: Icon(
        Icons.settings_rounded,
        color: _showSettings ? Theme.of(context).colorScheme.primary : null,
      ),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      tooltip: l10n.settings,
      onPressed: _showSettings ? _closeSettings : _openSettings,
    );

    return Scaffold(
      body: Stack(
        children: [
          // UI normal (title bar + sidebar + contenido + player). En
          // fullscreen queda DEBAJO del overlay dedicado.
          Column(
            children: [
              // En fullscreen la title bar se oculta (los botones de ventana
              // no aplican); F11/Esc devuelven el modo normal.
              if (!_fullscreen)
                CustomTitleBar(
                  title: barTitle,
                  actions: barActions,
                  trailing: barTrailing,
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PlaylistsSidebar(
                      openPlaylistId: openPlaylist?.id,
                      onSelectPlaylist: _selectPlaylist,
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          IndexedStack(
                            index: _showLyrics
                                ? 4
                                : (openPlaylist != null
                                      ? 2
                                      : (_showSettings ? 3 : _selectedIndex)),
                            children: [
                              HomeView(onSearch: _submitSearch),
                              SearchView(
                                searchRequest: _searchRequest,
                                onBack: _backToHome,
                              ),
                              if (openPlaylist != null)
                                PlaylistDetailView(
                                  key: ValueKey(openPlaylist.id),
                                  playlist: openPlaylist,
                                  onBack: () => _selectPlaylist(null),
                                  onUpdated: _onPlaylistUpdated,
                                )
                              else
                                const SizedBox.shrink(),
                              SettingsView(key: ValueKey(_settingsOpenCount)),
                              // TickerMode muta el ticker del sweep karaoke
                              // cuando las letras están ocultas. Con el modo
                              // fullscreen activo la instancia vive en el
                              // overlay (reparenting por _fsLyricsKey), así
                              // que aquí va un placeholder.
                              _showFsOverlay
                                  ? const SizedBox.shrink()
                                  : TickerMode(
                                      enabled: _showLyrics,
                                      child: LyricsView(key: _fsLyricsKey),
                                    ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                              child: PlayerBar(
                                queueOpen: _queueOpen,
                                lyricsOpen: _showLyrics,
                                onToggleLyrics: () => _showLyrics
                                    ? _closeLyrics()
                                    : _openLyrics(),
                                onToggleQueue: () {
                                  _queueUserToggled = true;
                                  final next = !_queueOpen;
                                  setState(() => _queueOpen = next);
                                  unawaited(
                                    context.read<SettingsStore>().saveQueueOpen(
                                      next,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    QueuePanel(open: _queueOpen),
                  ],
                ),
              ),
            ],
          ),
          // Overlay fullscreen: cubre TODO. Mientras anima la salida sigue
          // montado; al terminar desmonta vía onExited.
          if (_showFsOverlay)
            Positioned.fill(
              child: FullscreenPlayerView(
                active: _fullscreen,
                lyricsPanel: TickerMode(
                  enabled: true,
                  // Embebido: sin margen/sombra/fondo — las letras flotan
                  // sobre las olas del fondo fullscreen.
                  child: LyricsView(key: _fsLyricsKey, embedded: true),
                ),
                onRequestClose: () => unawaited(_setFullscreen(false)),
                onExited: () => setState(() => _showFsOverlay = false),
              ),
            ),
        ],
      ),
    );
  }
}
