import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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

  // OS media controls: SMTC (Win), Now Playing (macOS), MPRIS (Linux).
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

  if (Binaries.isDesktop) {
    await windowManager.ensureInitialized();
    if (Platform.isMacOS) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: true,
      );
    } else if (Platform.isLinux) {
      await windowManager.setAsFrameless();
    }
    // Intercept close to flush pending data before exit.
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {
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
      await windowManager.setResizable(true);
      try {
        await windowManager.maximize();
      } catch (_) {}
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Binaries.logBinaries();

  // Extrae (en segundo plano) la toolchain CPython/yt-dlp desde los assets
  // nativos de Android. Las primeras búsquedas/descargas avisarán "yt-dlp no
  // encontrado" hasta que termine (unos segundos).
  if (Binaries.isMobile) {
    unawaited(Binaries.ensureAndroidToolchain());

    // TEMP: prueba offline de la pipeline JNI (yt-dlp --version, sin red).
    unawaited(() async {
      try {
        await Binaries.ensureAndroidToolchain();
        const ch = MethodChannel('com.scrup.music.toolchain');
        final logPath =
            p.join((await getApplicationSupportDirectory()).path, 'ver.log');
        final res = await ch.invokeMethod<Map<dynamic, dynamic>>(
          'ytDlpRun',
          {'args': <String>['--version'], 'logPath': logPath},
        );
        final code = (res?['exitCode'] as num?)?.toInt() ?? 1;
        final out = (res?['output'] as String?) ?? '';
        debugPrint('[TEMP-VERSION] exitCode=$code output=${out.trim()}');
      } catch (e) {
        debugPrint('[TEMP-VERSION] ERROR $e');
      }
    }());
  }

  final database = AppDatabase();
  try {
    await database.ensureFavoritesPlaylist();
  } catch (_) {}

  final paletteCache = await PaletteCacheStore.load(database);

  final settings = SettingsStore();
  var initialLocale = const Locale('es');
  try {
    final saved = await settings.loadLocale();
    if (saved != null) initialLocale = parseStoredLocale(saved);
  } catch (_) {}
  var initialShuffleEnabled = false;
  try {
    final saved = await settings.loadShuffleEnabled();
    if (saved != null) initialShuffleEnabled = saved;
  } catch (_) {}
  var initialRepeatMode = LoopMode.off;
  try {
    final saved = await settings.loadRepeatMode();
    if (saved != null) {
      initialRepeatMode = LoopMode.values.asNameMap()[saved] ?? LoopMode.off;
    }
  } catch (_) {}
  var initialRadioEnabled = true;
  try {
    final saved = await settings.loadRadioEnabled();
    if (saved != null) initialRadioEnabled = saved;
  } catch (_) {}
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
    final resume = await settings.loadResumePosition();
    int positionFor(String trackId) =>
        resume != null && resume.trackId == trackId ? resume.seconds : 0;
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
  } catch (_) {}
}

class ScrupApp extends StatelessWidget {
  final AppDatabase database;
  final SettingsStore settings;

  final Locale initialLocale;
  final bool initialShuffleEnabled;
  final LoopMode initialRepeatMode;
  final bool initialRadioEnabled;
  final ScrupAudioHandler audioHandler;
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
          create: (context) {
            final searchService = context.read<SearchService>();
            final cache = context.read<AudioCacheService>();
            final db = context.read<AppDatabase>();
            final settings = context.read<SettingsStore>();
            // Debounce de la persistencia de la cola (ver onQueueChanged):
            // se cancela y reprograma en cada cambio de la cola.
            Timer? queueDebounce;
            final player = PlayerService(
              resolveSource: (track) async {
                final source = await cache.ensureStreaming(
                  track.id,
                  title: track.title,
                );
                return PlayableSource(source.path, isLocal: true);
              },
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
              preload: (track) => cache.preload(track.id, title: track.title),
              onEnriched: (track) async => db.updateTrackMetadata(track),
              onPlayed: (track) async => db.recordPlay(track),
              onShuffleChanged: (enabled) =>
                  settings.saveShuffleEnabled(enabled),
              onRadioChanged: (enabled) => settings.saveRadioEnabled(enabled),
              onRepeatChanged: (mode) => settings.saveRepeatMode(mode.name),
              onQueueChanged: (snapshot) async {
                queueDebounce?.cancel();
                queueDebounce = Timer(
                  const Duration(milliseconds: 300),
                  () => unawaited(_writeQueueSnapshot(settings, snapshot)),
                );
              },
            );
            player.shuffle.value = initialShuffleEnabled;
            player.repeatMode.value = initialRepeatMode;
            player.radio.value = initialRadioEnabled;
            context.read<ScrupAudioHandler>().attach(player);
            player.currentTrack.listen((t) {
              if (t != null) settings.saveLastTrackId(t.id);
            });
            Timer? volumeDebounce;
            player.volume.addListener(() {
              volumeDebounce?.cancel();
              volumeDebounce = Timer(
                const Duration(milliseconds: 300),
                () => settings.saveVolume(player.volume.value),
              );
            });
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
            unawaited(_restoreSession(player, settings, db));
            final palette = context.read<PaletteCacheStore>();
            if (Binaries.isDesktop) {
              windowManager.addListener(
                _AppCloseHandler(() async {
                  await _writeQueueSnapshot(settings, player.queueSnapshot);
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
            }
            return player;
          },
          dispose: (_, player) async {
            await player.dispose();
            await audioHandler.dispose();
          },
        ),
        ChangeNotifierProvider<ThemeController>(
          create: (context) => ThemeController(
            context.read<PlayerService>(),
            paletteCache: context.read<PaletteCacheStore>(),
            artworkCache: context.read<ArtworkCacheService>(),
          ),
        ),
        Provider<DiscordPresenceService>(
          create: (context) {
            final service = DiscordPresenceService(
              player: context.read<PlayerService>(),
              settings: context.read<SettingsStore>(),
            );
            if (Binaries.isDesktop) unawaited(service.start());
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProvider<SilenceSkipService>(
          create: (context) => SilenceSkipService(
            context.read<PlayerService>(),
            context.read<AudioCacheService>(),
            context.read<SettingsStore>(),
          ),
          lazy: false,
        ),
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

  ThemeData _buildTheme(Color? accent) {
    final seed = accent ?? kDefaultAccent;
    final fromSeed = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    // Neutral seeds (B/W artwork): force primary to silver.
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
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF0D0D0D),
        surfaceContainer: const Color(0xFF141414),
        surfaceContainerHigh: const Color(0xFF1B1B1B),
        surfaceContainerHighest: const Color(0xFF222222),
      ),
      scaffoldBackgroundColor: const Color(0xFF000000),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: const Color(0xFF000000),
        indicatorColor: seed.withValues(alpha: 0.16),
      ),
      iconButtonTheme: IconButtonThemeData(style: _clickCursorStyle),
      textButtonTheme: TextButtonThemeData(style: _clickCursorStyle),
      filledButtonTheme: FilledButtonThemeData(style: _clickCursorStyle),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF1E1E1E),
        surfaceTintColor: Colors.transparent,
        mouseCursor: WidgetStateProperty.all(SystemMouseCursors.click),
        menuPadding: EdgeInsets.zero,
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
