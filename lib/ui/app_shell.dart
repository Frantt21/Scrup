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
import 'views/library_view.dart';
import 'views/lyrics_view.dart';
import 'views/playlist_detail_view.dart';
import 'views/search_view.dart';
import 'views/settings_view.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/fullscreen_player_view.dart';
import 'widgets/mini_player.dart';
import 'widgets/player_bar.dart';
import 'widgets/playlists_sidebar.dart';
import 'widgets/queue_panel.dart';
import 'widgets/scrup_toasts.dart';

/// Main app shell: title bar, sidebar, views and player bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  StreamSubscription<String>? _errorSub;

  Playlist? _openPlaylist;

  bool _showSettings = false;
  int _settingsOpenCount = 0;
  final ValueNotifier<String?> _searchRequest = ValueNotifier<String?>(null);
  bool _queueOpen = false;
  bool _queueUserToggled = false;
  bool _showLyrics = false;
  bool _fullscreen = false;
  bool _showFsOverlay = false;
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
      // Sidecars (yt-dlp/ffmpeg) descend on desktop; on mobile the toolchain
      // lives in the app bundle (asset copy) — handled elsewhere.
      if (!Binaries.isDesktop) return;
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
    unawaited(_loadQueuePref());
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  // Global keyboard shortcuts. Returns true when consumed.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

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

    if (key == LogicalKeyboardKey.f11) {
      _setFullscreen(!_fullscreen);
      return true;
    }
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

    // ── Playback ─────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.space) {
      player.togglePlayPause();
      return true;
    }
    if (key == LogicalKeyboardKey.keyN) {
      player.next();
      return true;
    }
    if (key == LogicalKeyboardKey.keyP) {
      player.previous();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final pos = player.positionValue;
      final dur = player.durationValue;
      final target = pos + const Duration(seconds: 10);
      player.seek(dur != null && target > dur ? dur : target);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final pos = player.positionValue;
      final target = pos - const Duration(seconds: 10);
      player.seek(target.isNegative ? Duration.zero : target);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      player.setVolume((player.volume.value + 0.05).clamp(0.0, 1.0));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      player.setVolume((player.volume.value - 0.05).clamp(0.0, 1.0));
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      player.toggleMute();
      return true;
    }

    // ── Navigation ────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.keyL) {
      setState(() => _showLyrics = !_showLyrics);
      return true;
    }
    if (key == LogicalKeyboardKey.keyQ) {
      setState(() => _queueOpen = !_queueOpen);
      return true;
    }
    if (key == LogicalKeyboardKey.comma) {
      if (_showSettings) {
        _closeSettings();
      } else {
        _openSettings();
      }
      return true;
    }

    // ── Modes ─────────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.keyS) {
      player.toggleShuffle();
      return true;
    }
    if (key == LogicalKeyboardKey.keyR) {
      player.toggleRepeat();
      return true;
    }
    if (key == LogicalKeyboardKey.keyD) {
      player.toggleRadio();
      return true;
    }

    // ── Favorites ─────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFavorite();
      return true;
    }

    return false;
  }

  Future<void> _toggleFavorite() async {
    final player = context.read<PlayerService>();
    final track = player.currentTrackValue;
    if (track == null) return;
    final db = context.read<AppDatabase>();
    final id = await db.ensureFavoritesPlaylist();
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

  /// Botones laterales del ratón: button 4 (back) = canción anterior,
  /// button 5 (forward) = siguiente canción.
  void _handlePointerDown(PointerDownEvent event) {
    final player = context.read<PlayerService>();
    // event.buttons es un bitmask: bit 3 = button 4, bit 4 = button 5.
    if (event.buttons & 0x10 != 0) {
      // Button 5 (forward): siguiente canción.
      player.next();
    } else if (event.buttons & 0x08 != 0) {
      // Button 4 (back): canción anterior.
      player.previous();
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

  void _submitSearch(String query) {
    _searchRequest.value = query;
    setState(() => _selectedIndex = 1);
  }

  void _backToHome() {
    setState(() => _selectedIndex = 0);
  }

  void _openLyrics() {
    setState(() => _showLyrics = true);
  }

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

  void _onPlaylistUpdated(Playlist playlist) {
    if (_openPlaylist?.id != playlist.id) return;
    setState(() => _openPlaylist = playlist);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final openPlaylist = _openPlaylist;
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

    final bool mobile = Binaries.isMobile;

    return Listener(
      onPointerDown: _handlePointerDown,
      child: Scaffold(
      body: SafeArea(
        top: mobile,
        child: Stack(
        children: [
          Column(
            children: [
              if (!_fullscreen && !mobile)
                CustomTitleBar(
                  title: barTitle,
                  actions: barActions,
                  trailing: barTrailing,
                ),
              Expanded(
                child: mobile
                    // ── Móvil: sin title bar ni sidebars; todo el espacio ──
                    ? _buildMobileContent()
                    // ── Desktop: sidebar + contenido + cola ──────────────
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PlaylistsSidebar(
                            openPlaylistId: openPlaylist?.id,
                            onSelectPlaylist: _selectPlaylist,
                          ),
                          Expanded(child: _buildMainStack(barTitle)),
                          QueuePanel(open: _queueOpen),
                        ],
                      ),
              ),
              // ── Móvil: mini-player + NavigationBar ──────────────
              if (mobile && !_fullscreen) ...[
                MiniPlayer(
                  onOpenNowPlaying: () {},
                  onOpenQueue: _openQueueMobile,
                ),
                _buildMobileNavBar(),
              ],
            ],
          ),
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
      ),
    ),
    );
  }

  // Contenido principal compartido: pila de vistas (+ player flotante desktop).
  Widget _buildMainStack(String barTitle) {
    final openPlaylist = _openPlaylist;
    return Stack(
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
              onToggleQueue: () => _setQueueOpen(!_queueOpen),
            ),
          ),
        ),
      ],
    );
  }

  // Contenido móvil: la pila de vistas sin player flotante (el mini-player
  // vive abajo) y la cola como overlay a pantalla completa.
  Widget _buildMobileContent() {
    final openPlaylist = _openPlaylist;
    final content = Stack(
      children: [
        IndexedStack(
          index: _showLyrics
              ? 5
              : (openPlaylist != null
                    ? 3
                    : (_showSettings ? 4 : _selectedIndex)),
          children: [
            HomeView(onSearch: _submitSearch),
            SearchView(
              searchRequest: _searchRequest,
              onBack: _backToHome,
            ),
            LibraryView(
              onSelectPlaylist: _selectPlaylist,
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
            _showFsOverlay
                ? const SizedBox.shrink()
                : TickerMode(
                    enabled: _showLyrics,
                    child: LyricsView(key: _fsLyricsKey),
                  ),
          ],
        ),
        // Cola como overlay a pantalla completa en móvil.
        if (_queueOpen)
          Positioned.fill(
            child: QueuePanel(
              open: true,
              mobile: true,
              onClose: () => _setQueueOpen(false),
            ),
          ),
      ],
    );
    return content;
  }

  void _setQueueOpen(bool next) {
    _queueUserToggled = true;
    setState(() => _queueOpen = next);
    unawaited(context.read<SettingsStore>().saveQueueOpen(next));
  }

  void _openQueueMobile() => _setQueueOpen(!_queueOpen);

  // Barra de navegación inferior de Android (Inicio / Buscar / Librería / Ajustes).
  Widget _buildMobileNavBar() {
    final l10n = AppLocalizations.of(context);
    return NavigationBar(
      selectedIndex: _mobileNavIndex,
      onDestinationSelected: (i) {
        setState(() {
          _openPlaylist = null;
          _showLyrics = false;
          if (i == 3) {
            _showSettings = true;
          } else {
            _showSettings = false;
            _selectedIndex = i;
          }
        });
      },
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: l10n.home,
        ),
        NavigationDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search_rounded),
          label: l10n.searchTitle,
        ),
        NavigationDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music_rounded),
          label: l10n.library,
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings_rounded),
          label: l10n.settings,
        ),
      ],
    );
  }

  // Índice activo de la NavigationBar móvil: mapea el estado real de la app.
  int get _mobileNavIndex {
    if (_showSettings) return 3;
    return _selectedIndex;
  }
}
