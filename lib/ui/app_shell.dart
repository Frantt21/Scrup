import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/player_service.dart';
import 'views/home_view.dart';
import 'views/playlist_detail_view.dart';
import 'views/search_view.dart';
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

  /// Consulta de búsqueda lanzada desde el inicio: el HomeView la escribe y
  /// la SearchView la ejecuta al cambiar de vista.
  final ValueNotifier<String?> _searchRequest = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    // Errores de reproducción globales (URL expirada, 403, etc.)
    _errorSub = context.read<PlayerService>().errors.listen((message) {
      if (!mounted) return;
      showScrupSnackBar(
        ScaffoldMessenger.of(context),
        'Error de reproducción: $message',
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
    setState(() => _openPlaylist = playlist);
  }

  @override
  Widget build(BuildContext context) {
    final openPlaylist = _openPlaylist;

    return Scaffold(
      body: Column(
        children: [
          // Title bar personalizado (solo en desktop; en macOS se deja el nativo)
          if (!Platform.isMacOS) const CustomTitleBar(title: 'Scrup'),
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
                        index: openPlaylist != null ? 2 : _selectedIndex,
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
                            )
                          else
                            const SizedBox.shrink(),
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
