import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
// `hide Track`: media_kit exporta su propio modelo `Track`, que chocaría
// con el `Track` del dominio (core/track.dart) aquí en main.
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/binaries.dart';
import 'core/track.dart';
import 'data/database.dart';
import 'l10n/generated/app_localizations.dart';
import 'services/audio_cache_service.dart';
import 'services/artwork_cache_service.dart';
import 'services/search_service.dart';
import 'services/discord/discord_presence_service.dart';
import 'services/lyrics_service.dart';
import 'services/palette_cache_store.dart';
import 'services/player_service.dart';
import 'services/scrup_audio_handler.dart';
import 'services/settings_store.dart';
import 'services/silence_skip_service.dart';
import 'services/ytdlp_service.dart';
import 'ui/app_shell.dart';
import 'ui/locale_controller.dart';
import 'ui/theme_controller.dart';
import 'ui/widgets/scrup_toasts.dart';

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
  // 1440x800 y el tamaño por defecto 1400x800. La title bar personalizada
  // (CustomTitleBar en AppShell) se usa en las 3 plataformas:
  //  - Windows/Linux: ventana sin marco (setAsFrameless en Linux; en Windows
  //    titleBarStyle hidden) + botones de ventana propios (min/max/cerrar).
  //  - macOS: barra nativa oculta (TitleBarStyle.hidden) conservando los
  //    traffic lights nativos; la barra deja espacio para ellos y NO dibuja
  //    botones propios.
  await windowManager.ensureInitialized();
  if (Platform.isMacOS) {
    // macOS: ocultar la title bar nativa pero MANTENER los traffic lights
    // (rojo/amarillo/verde) que el sistema sigue dibujando y gestionando.
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: true,
    );
  } else if (Platform.isLinux) {
    // Linux: sin decoraciones del gestor de ventanas; la app dibuja su barra
    // y sus botones. (En Windows se hace vía titleBarStyle.hidden abajo.)
    await windowManager.setAsFrameless();
  }
  // El app controla el cierre de la ventana (X, Alt+F4, cierre del OS): se
  // intercepta para forzar el guardado pendiente (cola + colores) y solo
  // entonces destruir la ventana (ver _AppCloseHandler). Si la plataforma no
  // soporta setPreventClose, el cierre sigue el flujo nativo y el flush al
  // cerrar queda best-effort como antes.
  try {
    await windowManager.setPreventClose(true);
  } catch (_) {
    // Best-effort: sin preventClose no se puede garantizar el volcado.
  }
  final windowOptions = WindowOptions(
    size: const Size(1400, 800),
    minimumSize: const Size(1440, 800),
    center: true,
    title: 'Scrup',
    // Ocultar la nativa en Windows y macOS (macOS ya lo dejó configurado
    // arriba; aquí se mantiene para waitUntilReadyToShow). En Linux NO se
    // pasa (null): setTitleBarStyle(normal) DESHARÍA el setAsFrameless()
    // anterior reactivando la barra nativa del gestor de ventanas.
    titleBarStyle: (Platform.isWindows || Platform.isMacOS)
        ? TitleBarStyle.hidden
        : null,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // setResizable ANTES de maximize: en Windows, tocar el estilo de la
    // ventana (WS_THICKFRAME) DESPUÉS de maximizar puede restaurarla a modo
    // ventana (la app arrancaba maximizada y "saltaba" a ventana).
    await windowManager.setResizable(true);
    try {
      await windowManager.maximize();
    } catch (_) {}
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

  // Caché de colores de artworks en SQLite (best-effort): evita re-descargar
  // miniaturas entre sesiones solo para re-extraer la paleta. El flush al
  // cerrar lo hace el mismo _AppCloseHandler que la cola (registrado al
  // crear el PlayerService).
  final paletteCache = await PaletteCacheStore.load(database);

  // Instancia única de preferencias: se comparte entre los providers y la
  // carga del idioma inicial (restaurado entre sesiones).
  final settings = SettingsStore();
  var initialLocale = const Locale('es');
  try {
    final saved = await settings.loadLocale();
    if (saved != null) initialLocale = parseStoredLocale(saved);
  } catch (_) {}
  // Modo shuffle guardado (por defecto: desactivado). Se aplica de forma
  // SÍNCRONA al crear el PlayerService (no vía _restoreSession, que es
  // asíncrono y podría pisar un toggle del usuario en los primeros
  // instantes). Al arrancar no hay cola que barajar: el modo solo afecta a
  // la siguiente cola que se reproduzca.
  var initialShuffleEnabled = false;
  try {
    final saved = await settings.loadShuffleEnabled();
    if (saved != null) initialShuffleEnabled = saved;
  } catch (_) {}
  // Modo de repetición guardado (por defecto: off). Se aplica de forma
  // SÍNCRONA al crear el PlayerService, igual que el shuffle (si un valor
  // inválido quedó guardado, se cae al default con `?? LoopMode.off`).
  var initialRepeatMode = LoopMode.off;
  try {
    final saved = await settings.loadRepeatMode();
    if (saved != null) {
      initialRepeatMode = LoopMode.values.asNameMap()[saved] ?? LoopMode.off;
    }
  } catch (_) {}
  // Modo radio guardado (por defecto: activado, como el ValueNotifier del
  // player). Se aplica de forma SÍNCRONA al crear el PlayerService.
  var initialRadioEnabled = true;
  try {
    final saved = await settings.loadRadioEnabled();
    if (saved != null) initialRadioEnabled = saved;
  } catch (_) {}
  // Preferencia de omitir silencios: cargarla ANTES de crear los providers
  // para que el SilenceSkipService arranque con el valor guardado.
  try {
    await settings.loadSkipSilenceEnabled();
  } catch (_) {}

  runApp(
    ScrupApp(
      database: database,
      settings: settings,
      initialLocale: initialLocale,
      initialShuffleEnabled: initialShuffleEnabled,
      initialRepeatMode: initialRepeatMode,
      initialRadioEnabled: initialRadioEnabled,
      audioHandler: audioHandler,
      paletteCache: paletteCache,
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
    // Punto de reanudación (pista + segundos). La posición guardada solo
    // aplica si la pista restaurada es la misma que se estaba reproduciendo
    // al guardarla (validación por id): con un retraso de guardado nunca se
    // reanuda una pista distinta en los segundos de otra.
    final resume = await settings.loadResumePosition();
    int positionFor(String trackId) =>
        resume != null && resume.trackId == trackId ? resume.seconds : 0;
    // Restaurar la cola completa guardada (orden + posición + playlist
    // activa) para reanudar la sesión donde quedó. Las pistas que ya no
    // estén en la base (caché evictado, radio no registrada) se omiten; si
    // ninguna sobrevive, se cae al respaldo de la última pista.
    final savedQueue = await settings.loadQueue();
    if (savedQueue != null && savedQueue.isNotEmpty) {
      final tracks = <Track>[];
      for (final id in savedQueue) {
        final t = await db.getCachedTrack(id);
        if (t != null) tracks.add(t);
      }
      if (tracks.isNotEmpty) {
        final index = (await settings.loadQueueIndex() ?? 0).clamp(
          0,
          tracks.length - 1,
        );
        final playlistId = await settings.loadActivePlaylistId();
        final original = await settings.loadOriginalQueue();
        await player.restoreQueue(
          tracks,
          startIndex: index,
          playlistId: playlistId,
          originalTrackIds: original,
          positionSeconds: positionFor(tracks[index].id),
        );
        return;
      }
    }
    final lastId = await settings.loadLastTrackId();
    if (lastId == null) return;
    final track = await db.getCachedTrack(lastId);
    if (track != null) {
      await player.restoreLastTrack(
        track,
        positionSeconds: positionFor(track.id),
      );
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

  /// Modo shuffle guardado en la última sesión (por defecto: desactivado).
  /// Se aplica al crear el reproductor, antes de que la UI pueda tocarlo.
  final bool initialShuffleEnabled;

  /// Modo de repetición guardado en la última sesión (por defecto: off).
  final LoopMode initialRepeatMode;

  /// Modo radio inicial (restaurado de la última sesión).
  final bool initialRadioEnabled;

  /// Puente con los controles multimedia nativos del OS.
  final ScrupAudioHandler audioHandler;

  /// Caché de colores de artworks persistido en disco (compartido por el
  /// reproductor y el detalle de playlists).
  final PaletteCacheStore paletteCache;

  const ScrupApp({
    super.key,
    required this.database,
    required this.settings,
    required this.initialLocale,
    required this.initialShuffleEnabled,
    required this.initialRepeatMode,
    required this.initialRadioEnabled,
    required this.audioHandler,
    required this.paletteCache,
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
        Provider<ArtworkCacheService>(
          create: (_) => ArtworkCacheService(),
        ),
        Provider<SearchService>(
          create: (context) =>
              SearchService(ytDlp: context.read<YtDlpService>()),
        ),
        Provider<LyricsService>(
          create: (context) => LyricsService(context.read<AppDatabase>()),
        ),
        Provider<SettingsStore>(create: (_) => settings),
        Provider<PaletteCacheStore>(create: (_) => paletteCache),
        Provider<ScrupAudioHandler>(create: (_) => audioHandler),
        Provider<PlayerService>(
          // Inyecta la resolución de fuente (cache-first con yt-dlp) y la
          // búsqueda de radio. SIN enriquecimiento automático: InnerTube
          // (YT Music, filtro Songs) ya devuelve metadatos limpios y es la
          // fuente principal; Deezer queda solo para el editor manual.
          create: (context) {
            final searchService = context.read<SearchService>();
            final cache = context.read<AudioCacheService>();
            final db = context.read<AppDatabase>();
            final settings = context.read<SettingsStore>();
            // Debounce de la persistencia de la cola (ver onQueueChanged):
            // se cancela y reprograma en cada cambio de la cola.
            Timer? queueDebounce;
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
              // Radio: canciones del mismo artista/género SOLO con YouTube
              // Music (InnerTube): resultados limpios (canciones reales del
              // artista, sin covers/lives/mixes de yt-dlp). Si InnerTube no
              // da nada (fallo o sin red), cae a la búsqueda fusionada para
              // que la radio nunca muera en seco.
              recommend: (track) async {
                final query = track.artist.isNotEmpty
                    ? track.artist
                    : track.title;
                final clean = await searchService.recommendByArtist(
                  query,
                  limit: 10,
                );
                if (clean.isNotEmpty) return clean;
                return searchService.search(query, limit: 10);
              },
              // Precarga de la cola: cachea las siguientes pistas en segundo
              // plano (recursos limitados por el caché) para que el salto de
              // canción sea instantáneo.
              preload: (track) => cache.preload(track.id, title: track.title),
              // Persistir ediciones de metadatos del usuario (editor manual)
              // y cualquier actualización de la pista actual.
              onEnriched: (track) async => db.updateTrackMetadata(track),
              // Historial: registra cada pista que realmente empieza a sonar
              // (manual, auto-advance o radio)
              onPlayed: (track) async => db.recordPlay(track),
              // Persistir el modo shuffle (activo/desactivado) entre sesiones
              onShuffleChanged: (enabled) =>
                  settings.saveShuffleEnabled(enabled),
              // Persistir el modo radio (activo/desactivado) entre sesiones
              onRadioChanged: (enabled) => settings.saveRadioEnabled(enabled),
              // Persistir el modo de repetición (off/all/one) entre sesiones
              onRepeatChanged: (mode) => settings.saveRepeatMode(mode.name),
              // Persistir la cola completa (orden, orden pre-shuffle, índice
              // y playlist activa) para reanudarla al abrir. Con debounce
              // (mismo patrón que el volumen): los cambios de pista se
              // suceden con poca separación, y al reprogramar el timer solo
              // se persiste la ÚLTIMA instantánea, siempre consistente.
              onQueueChanged: (snapshot) async {
                queueDebounce?.cancel();
                queueDebounce = Timer(
                  const Duration(milliseconds: 300),
                  () => unawaited(_writeQueueSnapshot(settings, snapshot)),
                );
              },
            );
            // Aplicar los modos guardados de la última sesión de forma
            // síncrona (sin toggle: no baraja cola inexistente ni
            // re-persiste).
            player.shuffle.value = initialShuffleEnabled;
            player.repeatMode.value = initialRepeatMode;
            player.radio.value = initialRadioEnabled;
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
            // Persistir el punto de reanudación (pista + segundos) como mucho
            // cada 10s mientras hay reproducción (el guardado exacto al
            // cerrar lo hace _AppCloseHandler). Throttle por tiempo en vez de
            // un Timer por tick: el stream de posición emite decenas de ticks
            // por segundo y recrear un Timer en cada uno es trabajo inútil
            // (contribuye al consumo de CPU en reproducción). El id de la
            // pista se lee EN el momento de escribir, para que la pareja
            // siempre sea consistente.
            DateTime? lastResumeSave;
            player.position.listen((_) {
              if (player.positionValue <= Duration.zero) return;
              final now = DateTime.now();
              if (lastResumeSave != null &&
                  now.difference(lastResumeSave!) <
                      const Duration(seconds: 10)) {
                return;
              }
              lastResumeSave = now;
              final t = player.currentTrackValue;
              if (t == null) return;
              settings.saveResumePosition(player.positionValue.inSeconds, t.id);
            });
            // Restaurar la sesión anterior (volumen + última pista, pausada).
            unawaited(_restoreSession(player, settings, db));
            // Al cerrar la ventana, el app controla el cierre (setPreventClose
            // en main): se fuerza el guardado pendiente de la cola (el debounce
            // de onQueueChanged podría no haber escrito la última instantánea)
            // y del caché de colores, y solo entonces se destruye la ventana:
            // el volcado llega a disco antes de que el proceso salga. El caché
            // se captura aquí (síncrono) para no usar el context en el async.
            final palette = context.read<PaletteCacheStore>();
            windowManager.addListener(
              _AppCloseHandler(() async {
                // La instantánea se captura SÍNCRONA al correr el flush (el
                // player aún está vivo); la escritura es best-effort.
                await _writeQueueSnapshot(settings, player.queueSnapshot);
                // Punto de reanudación EXACTO: pista + segundos juntos.
                final current = player.currentTrackValue;
                if (current != null) {
                  await settings.saveResumePosition(
                    player.positionValue.inSeconds,
                    current.id,
                  );
                }
                await palette.flush();
              }),
            );
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
          create: (context) => ThemeController(
            context.read<PlayerService>(),
            paletteCache: context.read<PaletteCacheStore>(),
            artworkCache: context.read<ArtworkCacheService>(),
          ),
        ),
        // Presencia de Discord (Rich Presence): se conecta al IPC local de
        // Discord y publica la canción en reproducción. Se crea con el
        // reproductor ya listo (su provider viene antes) y arranca en
        // función de la configuración guardada.
        Provider<DiscordPresenceService>(
          create: (context) {
            final service = DiscordPresenceService(
              player: context.read<PlayerService>(),
              settings: context.read<SettingsStore>(),
            );
            unawaited(service.start());
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
        // Omitir silencios: servicio de FONDO que nadie consume desde la
        // UI — sin `lazy: false` NUNCA se instanciaría y la función quedaría
        // muerta. Debe ir DESPUÉS del provider de PlayerService: con
        // lazy:false el create corre al montar su propio nodo, y un provider
        // declarado antes no encontraría a PlayerService ("not found").
        ChangeNotifierProvider<SilenceSkipService>(
          create: (context) => SilenceSkipService(
            context.read<PlayerService>(),
            context.read<AudioCacheService>(),
            context.read<SettingsStore>(),
          ),
          lazy: false,
        ),
        // Idioma de la interfaz: al cambiar, el MaterialApp se reconstruye
        // con el nuevo locale (y se persiste entre sesiones).
        ChangeNotifierProvider<LocaleController>(
          create: (_) => LocaleController(initialLocale),
        ),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) {
          return Consumer<LocaleController>(
            builder: (context, localeController, _) {
              final app = MaterialApp(
                title: 'Scrup',
                debugShowCheckedModeBanner: false,
                locale: localeController.locale,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                themeAnimationDuration: const Duration(milliseconds: 700),
                themeAnimationCurve: Curves.easeInOut,
                theme: _buildTheme(themeController.accentColor),
                builder: (context, child) {
                  final app = Stack(
                    children: [
                      child ?? const SizedBox.shrink(),
                      const ScrupToastHost(),
                    ],
                  );
                  if (Platform.isLinux) {
                    return _LinuxRoundedCorners(child: app);
                  }
                  return app;
                },
                home: const AppShell(),
              );
              return app;
            },
          );
        },
      ),
    );
  }

  /// Tema oscuro negro puro con acento dinámico (lila por defecto, o el
  /// color extraído del artwork de la pista en reproducción).
  ThemeData _buildTheme(Color? accent) {
    final seed = accent ?? kDefaultAccent;
    final fromSeed = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    // Semilla NEUTRA (artwork B/N → plata): M3 inventa el hue baseline
    // azulado para semillas acromáticas y teñía todos los controles que
    // usan `colorScheme.primary` (shuffle activo, repeat, lyrics, radio,
    // queue, sliders, barra de tiempo). Forzar el primary al plata neutro.
    final isNeutral = HSLColor.fromColor(seed).saturation <
        kDefaultAccentNeutralThreshold;
    final scheme = isNeutral
        ? fromSeed.copyWith(primary: seed, onPrimary: const Color(0xFF1A1A1A))
        : fromSeed;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
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

/// Controla el cierre de la ventana junto a `setPreventClose(true)` (ver
/// main): al pedir cerrar, ejecuta [flush] —el guardado pendiente de la cola
/// y del caché de colores— y SOLO entonces destruye la ventana, garantizando
/// que el volcado llegue a disco antes de que el proceso salga. Best-effort:
/// si la persistencia falla, igual se cierra; y nunca cierra dos veces.
class _AppCloseHandler extends WindowListener {
  _AppCloseHandler(this.flush);

  final Future<void> Function() flush;

  bool _closing = false;

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    unawaited(_closeAfterFlush());
  }

  Future<void> _closeAfterFlush() async {
    try {
      // Tope de seguridad: si la persistencia se quedara colgada, no dejar
      // la ventana abierta para siempre (el guard _closing bloquearía los
      // siguientes intentos de cierre).
      await flush().timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (_) {
      // Nunca impedir el cierre por un fallo de persistencia.
    } finally {
      try {
        await windowManager.destroy();
      } catch (_) {
        // Ya cerrada o plataforma que no lo soporta: el cierre nativo sigue.
      }
    }
  }
}

/// En Linux, redondea las CUATRO esquinas de la ventana (estilo
/// GNOME/Handy). La ventana es TRANSPARENTE y sin marco (ver main y
/// my_application.cc: view y fondo de la ventana con alpha cuando el
/// escritorio compone), así que aquí se recorta el contenido a las esquinas
/// redondeadas y el escritorio se ve a través de ellas. Cuando la ventana
/// está maximizada NO se recorta: el contenido llega al borde de la pantalla
/// (como hace el propio escritorio con las ventanas maximizadas). En el resto
/// de plataformas no se usa: en Windows la ventana es opaca y cuadrada, y en
/// macOS el sistema redondea la ventana nativamente.
class _LinuxRoundedCorners extends StatefulWidget {
  const _LinuxRoundedCorners({required this.child});

  final Widget child;

  @override
  State<_LinuxRoundedCorners> createState() => _LinuxRoundedCornersState();
}

class _LinuxRoundedCornersState extends State<_LinuxRoundedCorners> {
  /// Radio de las esquinas, acorde a las ventanas redondeadas de GNOME/KDE.
  static const double _radius = 12;

  /// La app arranca maximizada; se corrige con [windowManager.isMaximized] en
  /// el primer frame y con los eventos de maximizar/desmaximizar.
  bool _maximized = true;

  _LinuxMaximizeListener? _listener;

  @override
  void initState() {
    super.initState();
    _listener = _LinuxMaximizeListener((maximized) {
      if (mounted && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    });
    windowManager.addListener(_listener!);
    // Sincronizar el estado real: algunos gestores ignoran el maximize del
    // arranque (best-effort) y la ventana puede arrancar en modo ventana.
    unawaited(_syncMaximized());
  }

  Future<void> _syncMaximized() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    } catch (_) {
      // Best-effort: sin el estado real se mantiene la ventana sin recortar.
    }
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) windowManager.removeListener(listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_maximized) return widget.child;
    return ClipRRect(
      // Las 4 esquinas: con la ventana frameless no hay barra nativa que
      // cubra la parte superior, así que el redondeo se aplica completo.
      borderRadius: BorderRadius.circular(_radius),
      // antiAlias: esquinas suaves sobre el escritorio (sin dientes).
      clipBehavior: Clip.antiAlias,
      child: widget.child,
    );
  }
}

/// Escucha los cambios de maximizado de la ventana (Linux) para recortar o no
/// las esquinas redondeadas.
class _LinuxMaximizeListener extends WindowListener {
  _LinuxMaximizeListener(this.onChanged);

  final ValueChanged<bool> onChanged;

  @override
  void onWindowMaximize() => onChanged(true);

  @override
  void onWindowUnmaximize() => onChanged(false);
}

/// Persiste la instantánea de la cola (orden, orden pre-shuffle, índice y
/// playlist activa). Compartida por el debounce de `onQueueChanged` y el
/// flush al cerrar la ventana. Best-effort: nunca lanza.
Future<void> _writeQueueSnapshot(
  SettingsStore settings,
  QueuePersistenceSnapshot snapshot,
) async {
  try {
    await settings.saveQueue(snapshot.trackIds);
    await settings.saveOriginalQueue(snapshot.originalTrackIds);
    await settings.saveQueueIndex(snapshot.index);
    await settings.saveActivePlaylistId(snapshot.playlistId);
  } catch (_) {
    // Silencioso: un fallo de persistencia al cerrar no debe romper nada.
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
