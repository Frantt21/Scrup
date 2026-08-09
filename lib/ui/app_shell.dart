import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/player_service.dart';
import 'views/home_view.dart';
import 'views/playlist_detail_view.dart';
import 'views/search_view.dart';
import 'views/settings_view.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/player_bar.dart';
import 'widgets/playlists_sidebar.dart';
import 'widgets/scrup_snackbar.dart';

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

  @override
  void initState() {
    super.initState();
    // Errores de reproducción globales (URL expirada, 403, etc.)
    _errorSub = context.read<PlayerService>().errors.listen((message) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showScrupSnackBar(
        ScaffoldMessenger.of(context),
        l10n.playbackErrorWithDetails(message),
      );
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
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

  void _selectPlaylist(Playlist? playlist) {
    setState(() {
      _openPlaylist = playlist;
      // Abrir una playlist cierra la configuración (y viceversa): solo hay
      // un contenido "abierto" a la vez además de inicio/búsqueda.
      _showSettings = false;
    });
  }

  void _openSettings() {
    setState(() {
      _showSettings = true;
      _openPlaylist = null;
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
    // Barra superior: con una playlist o la configuración abiertas muestra el
    // botón de volver y su nombre; el engranaje de configuración vive a la
    // derecha. Compartido entre la CustomTitleBar (Windows/Linux) y la barra
    // simple de macOS (donde la title bar nativa conserva los traffic lights).
    final barTitle = _showSettings
        ? l10n.settings
        : (openPlaylist?.name ?? 'Scrup');
    final Widget? barLeading = _showSettings || openPlaylist != null
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            tooltip: _showSettings ? l10n.backToHome : l10n.backToPlaylists,
            onPressed: _showSettings
                ? _closeSettings
                : () => _selectPlaylist(null),
          )
        : null;
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
          if (!Platform.isMacOS)
            CustomTitleBar(
              title: barTitle,
              leading: barLeading,
              trailing: barTrailing,
            )
          else
            // macOS: barra simple (sin área de arrastre ni botones de ventana;
            // los traffic lights nativos siguen en la title bar del sistema).
            _MacTopBar(
              title: barTitle,
              leading: barLeading,
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
                        index: openPlaylist != null
                            ? 2
                            : (_showSettings ? 3 : _selectedIndex),
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
                        ],
                      ),
                      // Player flotante tipo glass. El padding exterior es el
                      // margen flotante; las vistas usan kPlayerOverlayInset
                      // como padding inferior para no quedar ocultas.
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: const PlayerBar(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra superior para macOS: la title bar nativa se conserva (con sus
/// traffic lights), así que aquí solo se replican las acciones de la
/// CustomTitleBar (back + título + engranaje de configuración), sin área de
/// arrastre ni botones de ventana.
class _MacTopBar extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget? trailing;

  const _MacTopBar({required this.title, this.leading, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
