import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/binaries.dart';
import 'core/track.dart';
import 'data/database.dart';
import 'l10n/generated/app_localizations.dart';
import 'services/audio_cache_service.dart';
import 'services/artwork_cache_service.dart';
import 'services/just_audio_backend.dart';
import 'services/media_kit_backend.dart';
import 'services/artist_avatar_cache_store.dart';
import 'services/artist_cache_store.dart';
import 'services/search_cache_store.dart';
import 'services/search_history_store.dart';
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
    } catch (_) {}
    final windowOptions = WindowOptions(
      size: const Size(1400, 800),
      minimumSize: const Size(1440, 800),
      center: true,
      title: 'Scrup',
      // Hide the native bar on Windows and macOS (macOS already configured it above; kept here for waitUntilReadyToShow). On Linux it is NOT passed (null): setTitleBarStyle(normal) would UNDO the earlier setAsFrameless() and reactivate the native window manager bar.
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

  if (Binaries.isMobile) {
    // Edge-to-edge estilo forawn_mobile: barras de sistema transparentes y
    // la app dibuja DEBAJO de ellas (el artwork del playlist detail llega
    // hasta el borde superior y el fondo cubre la barra de navegación).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_systemOverlayStyle);
  }

  // Extrae (en segundo plano) la toolchain CPython/yt-dlp desde los assets
  // nativos de Android. Las primeras búsquedas/descargas avisarán "yt-dlp no
  // encontrado" hasta que termine (unos segundos).
  if (Binaries.isMobile) {
    unawaited(Binaries.ensureAndroidToolchain());
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
        Provider<ArtworkCacheService>(create: (_) => ArtworkCacheService()),
        Provider<SearchService>(
          create: (context) => SearchService(
            ytDlp: context.read<YtDlpService>(),
            // Persistent search cache: repeating a search (or opening the app and repeating yesterday's) responds from disk instantly.
            cache: SearchCacheStore(),
            // Artist details: one JSON per channel (24h TTL).
            artistCache: ArtistCacheStore(),
            // Channel avatars: a shared JSON; disk serves the avatar instantly and background revalidation updates it if the channel changed it.
            avatarCache: ArtistAvatarCacheStore(),
          ),
        ),
        Provider<LyricsService>(
          create: (context) => LyricsService(context.read<AppDatabase>()),
        ),
        // Search history (persistent): the Search view chips show it and a tap repeats the query.
        Provider<SearchHistoryStore>(create: (_) => SearchHistoryStore()),
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
              // Android: just_audio (ExoPlayer) - reuses the audio pipeline between tracks and transitions do not tear down the player. Desktop/flatpak: media_kit (libmpv).
              audioBackend: Platform.isAndroid
                  ? JustAudioBackend()
                  : MediaKitBackend(),
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
              // Path 2 of prefetch: tracks already cached -> isolate that reads their first bytes (hot page cache for the mount).
              prepareCached: cache.warmUpcoming,
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
            context.read<ScrupAudioHandler>().attach(player, db: db);
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
              return MaterialApp(
                title: 'Scrup',
                debugShowCheckedModeBanner: false,
                // No performance graph over the app (clean release).
                showPerformanceOverlay: false,
                locale: localeController.locale,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates:
                    AppLocalizations.localizationsDelegates,
                // Duration ZERO on purpose: AnimatedTheme rebuilds the entire dependent tree on EVERY animation frame; at 200ms that was ~12 expensive frames per change. The dynamic tint is preserved (applied at once in a single rebuild) and the smoothness comes from the 350ms surface fades.
                // (Lesson from forawn_mobile: static chrome + local accents; here the global tint is kept but instant.)
                themeAnimationDuration: Duration.zero,
                themeAnimationCurve: Curves.easeInOut,
                // Theme seeded with the current track's accent: it tints the primary and other derived elements across the whole app. The seed arrives ~400ms after the surface accent to avoid stacking the re-theme on top of the change window.
                theme: _buildTheme(themeController.themeSeed),
                builder: (context, child) {
                  Widget core = Stack(
                    children: [
                      child ?? const SizedBox.shrink(),
                      const ScrupToastHost(),
                    ],
                  );
                  if (Platform.isLinux) {
                    core = _LinuxRoundedCorners(child: core);
                  }
                  if (Binaries.isMobile) {
                    // Reaplica el estilo de barras en cada build (persistente
                    // también para rutas empujadas).
                    core = AnnotatedRegion<SystemUiOverlayStyle>(
                      value: _systemOverlayStyle,
                      child: core,
                    );
                  }
                  return core;
                },
                home: const AppShell(),
              );
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
    final isNeutral =
        HSLColor.fromColor(seed).saturation < kDefaultAccentNeutralThreshold;
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

/// Controls window close together with `setPreventClose(true)` (see main): on close request, it runs [flush] —the pending save of the queue and color cache— and ONLY then destroys the window, ensuring the flush reaches disk before the process exits. Best-effort: if persistence fails, it still closes; and it never closes twice.
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
      // Safety cap: if persistence got stuck, do not leave the window open forever (the _closing guard would block further close attempts).
      await flush().timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (_) {
      // Never block close because of a persistence failure.
    } finally {
      try {
        await windowManager.destroy();
      } catch (_) {
        // Already closed or platform that does not support it: the native close still proceeds.
      }
    }
  }
}

/// On Linux, rounds the FOUR corners of the window (GNOME/Handy style). The window is TRANSPARENT and frameless (see main and my_application.cc: the view and window background have alpha when the desktop composes), so here the content is clipped to the rounded corners and the desktop shows through them. When the window is maximized, it is NOT clipped: the content reaches the screen edge (as the desktop itself does with maximized windows). On the rest of the platforms it is not used: on Windows the window is opaque and square, and on macOS the system rounds the window natively.
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
      // Sync the real state: some managers ignore the startup maximize (best-effort) and the window may start in windowed mode.
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

/// Barras de sistema transparentes (edge-to-edge), igual que forawn_mobile:
/// status y nav bar no dibujan fondo, los iconos siempre claros (la app es
/// oscura) y sin scrim de contraste.
const SystemUiOverlayStyle _systemOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

/// Persists the queue snapshot (order, pre-shuffle order, index and active playlist). Shared by the `onQueueChanged` debounce and the flush on window close. Best-effort: never throws.
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

/// Hand cursor (pointer) when the button is enabled and the normal cursor when disabled. Shared by the three button themes.
final ButtonStyle _clickCursorStyle = ButtonStyle(
  mouseCursor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled)
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
  ),
);
