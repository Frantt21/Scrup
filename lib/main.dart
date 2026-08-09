import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/binaries.dart';
import 'data/database.dart';
import 'services/audio_cache_service.dart';
import 'services/deezer_service.dart';
import 'services/player_service.dart';
import 'services/settings_store.dart';
import 'services/ytdlp_service.dart';
import 'ui/app_shell.dart';
import 'ui/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Ventana con title bar oculto (Windows/Linux) para usar el personalizado
  await windowManager.ensureInitialized();
  if (!Platform.isMacOS) {
    const windowOptions = WindowOptions(
      size: Size(1120, 720),
      minimumSize: Size(760, 520),
      center: true,
      title: 'Scrup',
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Binaries.logBinaries();

  // Crear la base y asegurar la playlist de Favoritos antes de arrancar
  // (best-effort: si falla, se crea la primera vez que se necesite).
  final database = AppDatabase();
  try {
    await database.ensureFavoritesPlaylist();
  } catch (_) {}

  runApp(ScrupApp(database: database));
}

/// Restaura la sesión anterior al arrancar: el volumen y la última pista
/// reproducida (queda cargada y pausada, lista para continuar con play).
/// Best-effort: si algo falla, la app arranca con los valores por defecto.
Future<void> _restoreSession(
  PlayerService player,
  SettingsStore settings,
  AppDatabase db,
) async {
  try {
    final volume = await settings.loadVolume();
    if (volume != null) {
      await player.setVolume(volume.clamp(0.0, 1.0));
    }
    final lastId = await settings.loadLastTrackId();
    if (lastId == null) return;
    final track = await db.getCachedTrack(lastId);
    if (track != null) {
      await player.restoreLastTrack(track);
    }
  } catch (_) {
    // La restauración nunca debe impedir el arranque.
  }
}

class ScrupApp extends StatelessWidget {
  final AppDatabase database;

  const ScrupApp({super.key, required this.database});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>(create: (_) => database),
        Provider<YtDlpService>(create: (_) => YtDlpService()),
        Provider<AudioCacheService>(
          create: (context) =>
              AudioCacheService(ytdlp: context.read<YtDlpService>()),
        ),
        Provider<DeezerService>(create: (_) => DeezerService()),
        Provider<SettingsStore>(create: (_) => SettingsStore()),
        Provider<PlayerService>(
          // Inyecta la resolución de fuente (cache-first con yt-dlp), la
          // búsqueda de radio y el enriquecimiento de metadatos (Deezer).
          create: (context) {
            final ytdlp = context.read<YtDlpService>();
            final cache = context.read<AudioCacheService>();
            final deezer = context.read<DeezerService>();
            final db = context.read<AppDatabase>();
            final settings = context.read<SettingsStore>();
            final player = PlayerService(
              // Cache-first con reproducción progresiva: si la pista no
              // está cacheada, se empieza a reproducir en cuanto hay datos
              // y la descarga continúa en segundo plano quedando en disco.
              resolveSource: (track) async {
                final source = await cache.ensureStreaming(
                  track.id,
                  title: track.title,
                );
                return PlayableSource(source.path, isLocal: true);
              },
              // Radio: busca canciones del mismo artista/género
              recommend: (track) async {
                final query = track.artist.isNotEmpty
                    ? track.artist
                    : track.title;
                return ytdlp.search(query, limit: 10);
              },
              // Metadatos: Deezer aporta título/álbum/portada limpios
              enrich: (track) async =>
                  deezer.apply(track, await deezer.enrich(track)),
              // Persistir el enriquecimiento cuando llega (sin bloquear la
              // reproducción): así las recientes muestran el artwork real.
              onEnriched: (track) async => db.updateTrackMetadata(track),
              // Historial: registra cada pista que realmente empieza a sonar
              // (manual, auto-advance o radio)
              onPlayed: (track) async => db.recordPlay(track),
            );
            // Persistir la última pista cuando cambia.
            player.currentTrack.listen((t) {
              if (t != null) settings.saveLastTrackId(t.id);
            });
            // Persistir el volumen con debounce: el drag del slider emite
            // decenas de cambios por segundo y no conviene escribir a disco
            // en cada tick.
            Timer? volumeDebounce;
            player.volume.addListener(() {
              volumeDebounce?.cancel();
              volumeDebounce = Timer(
                const Duration(milliseconds: 300),
                () => settings.saveVolume(player.volume.value),
              );
            });
            // Restaurar la sesión anterior (volumen + última pista, pausada).
            unawaited(_restoreSession(player, settings, db));
            return player;
          },
          dispose: (_, player) => player.dispose(),
        ),
        // Tema dinámico: el color de acento sigue al artwork de la pista.
        // ThemeController es un ChangeNotifier, así que necesita
        // ChangeNotifierProvider (Provider rechaza subtipos de Listenable).
        // ChangeNotifierProvider libera el notifier automáticamente.
        ChangeNotifierProvider<ThemeController>(
          create: (context) => ThemeController(context.read<PlayerService>()),
        ),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) => MaterialApp(
          title: 'Scrup',
          debugShowCheckedModeBanner: false,
          // Transición suave cuando el color cambia de pista a pista
          themeAnimationDuration: const Duration(milliseconds: 700),
          themeAnimationCurve: Curves.easeInOut,
          theme: _buildTheme(themeController.accentColor),
          home: const AppShell(),
        ),
      ),
    );
  }

  /// Tema oscuro negro puro con acento dinámico (lila por defecto, o el
  /// color extraído del artwork de la pista en reproducción).
  ThemeData _buildTheme(Color? accent) {
    final seed = accent ?? kDefaultAccent;
    return ThemeData(
      useMaterial3: true,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.dark,
          ).copyWith(
            // Negro puro como color base
            surface: const Color(0xFF000000),
            // Paneles casi-negros escalonados para dar profundidad
            surfaceContainerLowest: const Color(0xFF000000),
            surfaceContainerLow: const Color(0xFF0D0D0D),
            surfaceContainer: const Color(0xFF141414),
            surfaceContainerHigh: const Color(0xFF1B1B1B),
            surfaceContainerHighest: const Color(0xFF222222),
          ),
      scaffoldBackgroundColor: const Color(0xFF000000),
      // Sutil tinte del acento en superficies de navegación
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: const Color(0xFF000000),
        indicatorColor: seed.withValues(alpha: 0.16),
      ),
    );
  }
}
