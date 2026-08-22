import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
        final initial = 'Descargando binarios de audio… Esto puede tardar unos segundos.';
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

  /// Abre la vista de lyrics (cierra settings/playlist si estaban abiertas).
  void _openLyrics() {
    setState(() {
      _showLyrics = true;
      _showSettings = false;
      _openPlaylist = null;
    });
  }

  /// Cierra la vista de lyrics y vuelve al inicio.
  void _closeLyrics() {
    setState(() {
      _showLyrics = false;
      _selectedIndex = 0;
    });
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
          icon: const Icon(Icons.home_outlined),
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
          icon: const Icon(Icons.search_outlined),
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
        Icons.settings_outlined,
        color: _showSettings ? Theme.of(context).colorScheme.primary : null,
      ),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      tooltip: l10n.settings,
      onPressed: _showSettings ? _closeSettings : _openSettings,
    );

    return Scaffold(
      body: Column(
        children: [
          CustomTitleBar(
            title: barTitle,
            actions: barActions,
            trailing: barTrailing,
          ),
          Expanded(
            // El sidebar ocupa su propio espacio; el player flota SOLO sobre
            // el área de contenido (no cubre el sidebar).
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
                      // Contenido con el player flotando ENCIMA (el contenido
                      // se extiende por detrás y el blur lo difumina). El
                      // detalle de playlist vive en el IndexedStack para
                      // preservar el estado de Home/Buscar al volver.
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
                            // Key por playlist: si se cambia de una playlist a
                            // otra con el detalle abierto, se fuerza un State
                            // nuevo (el IndexedStack reutiliza el State si el
                            // widget es del mismo tipo y re-suscribiría las
                            // canciones de la playlist anterior).
                            PlaylistDetailView(
                              key: ValueKey(openPlaylist.id),
                              playlist: openPlaylist,
                              onBack: () => _selectPlaylist(null),
                              onUpdated: _onPlaylistUpdated,
                            )
                          else
                            const SizedBox.shrink(),
                          SettingsView(key: ValueKey(_settingsOpenCount)),
                          // TickerMode: con la vista de letras oculta se
                          // MUTA el ticker del sweep karaoke (createTicker
                          // respeta TickerMode). Sin esto, mientras suena
                          // música el ticker escribe la posición cada frame,
                          // fuerza un frame por vsync (60+) y repinta TODA
                          // la UI glass (blurs) aunque nadie vea las letras
                          // — principal fuente de CPU en reproducción.
                          TickerMode(enabled: _showLyrics, child: LyricsView()),
                        ],
                      ),
                      // Player flotante tipo glass. El padding exterior es el
                      // margen flotante, alineado lateralmente con los
                      // contenedores (12); las vistas usan kPlayerOverlayInset
                      // como padding inferior para no quedar ocultas.
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
                              // Recordar la última elección entre sesiones.
                              unawaited(
                                context.read<SettingsStore>().saveQueueOpen(
                                  next,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      // El host de toasts vive en el builder del MaterialApp
                      // (main.dart) para flotar por encima de los diálogos.
                    ],
                  ),
                ),
                // Cola: panel glass que se desliza desde la derecha y EMPUJA
                // el contenedor principal (contenido + player). Vive en el
                // Row para que el ancho animado corra el contenido, no para
                // superponerse.
                QueuePanel(open: _queueOpen),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

