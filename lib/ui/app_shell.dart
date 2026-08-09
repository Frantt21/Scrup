import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/player_service.dart';
import 'views/home_view.dart';
import 'views/playlists_view.dart';
import 'views/search_view.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/player_bar.dart';

/// Contenedor principal de la app: title bar personalizado, navegación
/// lateral (Inicio / Buscar / Playlists) y reproductor inferior.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  StreamSubscription<String>? _errorSub;

  static const _titles = ['Inicio', 'Buscar', 'Playlists'];
  static const _icons = [
    Icons.home_outlined,
    Icons.search,
    Icons.queue_music,
  ];

  @override
  void initState() {
    super.initState();
    // Errores de reproducción globales (URL expirada, 403, etc.)
    _errorSub = context.read<PlayerService>().errors.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error de reproducción: $message')),
      );
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Title bar personalizado (solo en desktop; en macOS se deja el nativo)
          if (!Platform.isMacOS) const CustomTitleBar(title: 'Scrup'),
          Expanded(
            child: Row(
              children: [
                // Navegación lateral
                NavigationRail(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (i) => setState(() => _selectedIndex = i),
                  labelType: NavigationRailLabelType.all,
                  leading: const SizedBox(height: 16),
                  destinations: [
                    for (var i = 0; i < _titles.length; i++)
                      NavigationRailDestination(
                        icon: Icon(_icons[i]),
                        selectedIcon: Icon(
                          i == 0 ? Icons.home : _icons[i],
                        ),
                        label: Text(_titles[i]),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                // Contenido de la vista activa
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: const [
                      HomeView(),
                      SearchView(),
                      PlaylistsView(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const PlayerBar(),
        ],
      ),
    );
  }
}
