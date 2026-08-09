import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/binaries.dart';
import 'data/database.dart';
import 'l10n/generated/app_localizations.dart';
import 'services/audio_cache_service.dart';
import 'services/deezer_service.dart';
import 'services/player_service.dart';
import 'services/scrup_audio_handler.dart';
import 'services/settings_store.dart';
import 'services/ytdlp_service.dart';
import 'ui/app_shell.dart';
import 'ui/locale_controller.dart';
import 'ui/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Controles multimedia nativos del OS: SMTC en Windows (vía el paquete
  // `audio_service_win`, que se registra solo — audio_service por sí solo
  // NO soporta Windows), Now Playing en macOS, y MPRIS en Linux (con el
  // paquete compañero `audio_service_mpris`). El handler se crea aquí pero
  // se conecta al reproductor cuando el árbol de providers construye el
  // PlayerService ([attach]). Best-effort: si el OS no lo soporta, la app
  // sigue funcionando sin controles nativos.
  ScrupAudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => ScrupAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.scrup.music.channel',
        androidNotificationChannelName: 'Scrup',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {
    audioHandler = ScrupAudioHandler();
  }

  // Ventana: abre SIEMPRE maximizada y, en modo ventana, el mínimo es
  // 1220x700 y el tamaño por defecto 1280x800. La title bar personalizada
  // (ocultando la nativa) solo se usa en Windows; en Linux y macOS se deja la
  // nativa de la distro/OS (cada gestor de ventanas de Linux — Mutter/KWin/
  // XFWM y otros — dibuja la suya, y ocultarla es poco fiable y propenso a
  // fugas de listeners en algunos WMs).
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(1280, 800),
    minimumSize: const Size(1220, 700),
    center: true,
    title: 'Scrup',
    // Ocultar la nativa solo en Windows (donde la personalizada la sustituye
    // de forma fiable). En Linux/macOS, `normal`.
    titleBarStyle: Platform.isWindows
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Maximizar ANTES de mostrar (la ventana se crea oculta): se ve
    // directamente maximizada sin parpadeo. En Windows es determinista y
    // debe cumplirse siempre; en Linux/macOS es best-effort porque algunos
    // gestores de Linux/Wayland ignoran el maximize antes de mapear la
    // ventana, y nunca debe impedir el arranque.
    if (Platform.isWindows) {
      await windowManager.maximize();
    } else {
      try {
        await windowManager.maximize();
      } catch (_) {}
    }
    await windowManager.show();
    await windowManager.focus();
  });

  Binaries.logBinaries();

  // Crear la base y asegurar la playlist de Favoritos antes de arrancar
  // (best-effort: si falla, se crea la primera vez que se necesite).
  final database = AppDatabase();
  try {
    await database.ensureFavoritesPlaylist();
  } catch (_) {}

  // Instancia única de preferencias: se comparte entre los providers y la
  // carga del idioma inicial (restaurado entre sesiones).
  final settings = SettingsStore();
  var initialLocale = const Locale('es');
  try {
    final saved = await settings.loadLocale();
    if (saved != null) initialLocale = parseStoredLocale(saved);
  } catch (_) {}

  runApp(
    ScrupApp(
      database: database,
      settings: settings,
      initialLocale: initialLocale,
      audioHandler: audioHandler,
    ),
  );
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
  final SettingsStore settings;

  /// Idioma inicial: el guardado en la última sesión (o español).
  final Locale initialLocale;

  /// Puente con los controles multimedia nativos del OS.
  final ScrupAudioHandler audioHandler;

  const ScrupApp({
    super.key,
    required this.database,
    required this.settings,
    required this.initialLocale,
    required this.audioHandler,
  });

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
        Provider<SettingsStore>(create: (_) => settings),
        Provider<ScrupAudioHandler>(create: (_) => audioHandler),
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
            // Controles nativos del OS: sincronizar metadatos/estado y
            // reenviar comandos (play/pausa/siguiente/anterior/seek).
            context.read<ScrupAudioHandler>().attach(player);
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
          dispose: (_, player) async {
            await player.dispose();
            // Liberar las suscripciones del handler nativo del OS (los
            // streams del reproductor ya están cerrados).
            await audioHandler.dispose();
          },
        ),
        // Tema dinámico: el color de acento sigue al artwork de la pista.
        // ThemeController es un ChangeNotifier, así que necesita
        // ChangeNotifierProvider (Provider rechaza subtipos de Listenable).
        // ChangeNotifierProvider libera el notifier automáticamente.
        ChangeNotifierProvider<ThemeController>(
          create: (context) => ThemeController(context.read<PlayerService>()),
        ),
        // Idioma de la interfaz: al cambiar, el MaterialApp se reconstruye
        // con el nuevo locale (y se persiste entre sesiones).
        ChangeNotifierProvider<LocaleController>(
          create: (_) => LocaleController(initialLocale),
        ),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) => Consumer<LocaleController>(
          builder: (context, localeController, _) => MaterialApp(
            title: 'Scrup',
            debugShowCheckedModeBanner: false,
            // i18n: delegados + idiomas soportados (es/en). El locale activo
            // lo decide LocaleController (persistido entre sesiones).
            locale: localeController.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            // Transición suave cuando el color cambia de pista a pista
            themeAnimationDuration: const Duration(milliseconds: 700),
            themeAnimationCurve: Curves.easeInOut,
            theme: _buildTheme(themeController.accentColor),
            home: const AppShell(),
          ),
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
      // Cursor de mano en TODOS los botones al hacer hover: en desktop los
      // IconButton/TextButton/FilledButton no cambian el cursor por defecto.
      iconButtonTheme: IconButtonThemeData(style: _clickCursorStyle),
      textButtonTheme: TextButtonThemeData(style: _clickCursorStyle),
      filledButtonTheme: FilledButtonThemeData(style: _clickCursorStyle),
      // Menús contextuales (clic derecho) y dropdowns: fondo oscuro con
      // borde sutil y sombra suave, coherente con el cristal del resto de la
      // app. Aplica de una sola vez a todos los showMenu. (Los iconos de los
      // items se estilizan en ContextMenuItem con el acento.)
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF1E1E1E),
        surfaceTintColor: Colors.transparent,
        // Sin padding vertical: el hover de los items llega completo al
        // borde superior/inferior del menú (los showMenu pasan clipBehavior
        // antiAlias para recortarlo a las esquinas redondeadas).
        menuPadding: EdgeInsets.zero,
        // En Material 3 el texto de los items usa `labelTextStyle` (no
        // `textStyle`), que se aplica vía AnimatedDefaultTextStyle.
        labelTextStyle: WidgetStatePropertyAll(
          const TextStyle(color: Colors.white, fontSize: 14),
        ),
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF141414),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(const Color(0xFF1E1E1E)),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
        ),
      ),
      // Tooltips: negro cristal en vez del blanco por defecto, con un borde
      // sutil para que no se fundan con el fondo negro puro.
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 350),
      ),
    );
  }
}

/// Cursor de mano (pointer) cuando el botón está habilitado y el cursor
/// normal cuando está deshabilitado. Compartido por los tres temas de botón.
final ButtonStyle _clickCursorStyle = ButtonStyle(
  mouseCursor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled)
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
  ),
);
