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
import 'services/deezer_service.dart';
import 'services/discord/discord_presence_service.dart';
import 'services/palette_cache_store.dart';
import 'services/player_service.dart';
import 'services/scrup_audio_handler.dart';
import 'services/settings_store.dart';
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
  // 1220x700 y el tamaño por defecto 1280x800. La title bar personalizada
  // (ocultando la nativa) solo se usa en Windows; en Linux y macOS se deja la
  // nativa de la distro/OS (cada gestor de ventanas de Linux — Mutter/KWin/
  // XFWM y otros — dibuja la suya, y ocultarla es poco fiable y propenso a
  // fugas de listeners en algunos WMs).
  await windowManager.ensureInitialized();
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

  // Caché de colores de artworks en disco (best-effort): evita re-descargar
  // miniaturas entre sesiones solo para re-extraer la paleta. El flush al
  // cerrar lo hace el mismo _AppCloseHandler que la cola (registrado al
  // crear el PlayerService).
  final paletteCache = await PaletteCacheStore.load();

  // Instancia única de preferencias: se comparte entre los providers y la
  // carga del idioma inicial (restaurado entre sesiones).
  final settings = SettingsStore();
  var initialLocale = const Locale('es');
  try {
    final saved = await settings.loadLocale();
    if (saved != null) initialLocale = parseStoredLocale(saved);
  } catch (_) {}
  // Cargar la preferencia de animación del player ANTES de runApp: el
  // ValueNotifier queda con el valor guardado desde el primer frame (si solo
  // lo cargara Configuración, el player animaría hasta abrirla).
  try {
    await settings.loadPlayerAnimationEnabled();
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

  runApp(
    ScrupApp(
      database: database,
      settings: settings,
      initialLocale: initialLocale,
      initialShuffleEnabled: initialShuffleEnabled,
      initialRepeatMode: initialRepeatMode,
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
        Provider<DeezerService>(create: (_) => DeezerService()),
        Provider<SettingsStore>(create: (_) => settings),
        Provider<PaletteCacheStore>(create: (_) => paletteCache),
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
              // Radio: busca canciones del mismo artista/género
              recommend: (track) async {
                final query = track.artist.isNotEmpty
                    ? track.artist
                    : track.title;
                return ytdlp.search(query, limit: 10);
              },
              // Precarga de la cola: cachea las siguientes pistas en segundo
              // plano (recursos limitados por el caché) para que el salto de
              // canción sea instantáneo.
              preload: (track) => cache.preload(track.id, title: track.title),
              // Metadatos: Deezer aporta título/álbum/portada limpios
              enrich: (track) async =>
                  deezer.apply(track, await deezer.enrich(track)),
              // Persistir el enriquecimiento cuando llega (sin bloquear la
              // reproducción): así las recientes muestran el artwork real.
              onEnriched: (track) async => db.updateTrackMetadata(track),
              // Historial: registra cada pista que realmente empieza a sonar
              // (manual, auto-advance o radio)
              onPlayed: (track) async => db.recordPlay(track),
              // Persistir el modo shuffle (activo/desactivado) entre sesiones
              onShuffleChanged: (enabled) =>
                  settings.saveShuffleEnabled(enabled),
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
            // Persistir el punto de reanudación (pista + segundos) con
            // debounce: el stream de posición emite decenas de ticks por
            // segundo; se guarda cada 10s mientras hay reproducción. El id de
            // la pista se lee EN el momento de escribir, para que la pareja
            // siempre sea consistente (la escritura exacta al cerrar la hace
            // _AppCloseHandler).
            Timer? positionDebounce;
            player.position.listen((_) {
              if (player.positionValue <= Duration.zero) return;
              positionDebounce?.cancel();
              positionDebounce = Timer(const Duration(seconds: 10), () {
                final t = player.currentTrackValue;
                if (t == null) return;
                settings.saveResumePosition(
                  player.positionValue.inSeconds,
                  t.id,
                );
              });
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
            // El host de toasts vive AQUÍ (sobre el navigator raíz), no dentro
            // del AppShell: así las notificaciones flotan por encima de los
            // diálogos/modales (p. ej. el de "añadir a playlist").
            builder: (context, child) => Stack(
              children: [
                child ?? const SizedBox.shrink(),
                const ScrupToastHost(),
              ],
            ),
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
