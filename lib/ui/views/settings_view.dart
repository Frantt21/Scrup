import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:drift/drift.dart' show OrderingTerm;

import '../../core/version.g.dart';
import '../../core/binaries.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/audio_cache_service.dart';
import '../../services/discord/discord_presence_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/settings_store.dart';
import '../locale_controller.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
import '../widgets/scrup_toasts.dart';

/// Pantalla de configuración: contenedor flotante tipo glass (como el
/// detalle de playlist) con tres secciones: idioma (i18n, persistido entre
/// sesiones), caché (tamaño usado / vaciar) y acerca de.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  CacheStats? _stats;
  bool _clearing = false;

  // ── Recalculo de paletas de artwork ────────────────────────────────────
  List<Playlist>? _playlists;
  Playlist? _selectedPlaylist;
  bool _recalculating = false;
  int _recalcDone = 0;
  int _recalcTotal = 0;

  /// Estado de la presencia de Discord (cargado desde el store al abrir).
  bool _discordEnabled = false;

  /// Modo karaoke (sweep palabra por palabra) de los lyrics.
  bool _lyricsSweepEnabled = false;

  /// Omitir silencios (saltar huecos sin música automáticamente).
  bool _skipSilenceEnabled = true;

  /// Límite del caché de audio en MiB (null = por defecto, 40 GiB).
  int? _cacheLimitMb;

  /// Opciones predefinidas del límite del caché (en MiB).
  static const List<int> _cacheLimitOptions = [
    512,
    1024,
    2048,
    5120,
    10240,
    20480,
    40960,
  ];

  /// Idiomas soportados: el nombre se muestra en el propio idioma (cada
  /// usuario lo reconoce aunque aún no lea la interfaz).
  ///
  /// IMPORTANTE: mantener en sync con los ARB de `lib/l10n/` — al agregar un
  /// idioma nuevo hay que crear su `app_xx.arb`, regenerar (`flutter
  /// gen-l10n`) y añadirlo aquí para que aparezca en el dropdown.
  static const List<_LocaleOption> _localeOptions = [
    _LocaleOption(Locale('es'), 'Español'),
    _LocaleOption(Locale('en'), 'English'),
    _LocaleOption(Locale('pt', 'BR'), 'Português (Brasil)'),
    _LocaleOption(Locale('ru'), 'Русский'),
    _LocaleOption(Locale('ja'), '日本語'),
    _LocaleOption(Locale('ko'), '한국어'),
    _LocaleOption(Locale('zh'), '中文'),
  ];

  @override
  void initState() {
    super.initState();
    _refreshStats();
    _loadDiscordPrefs();
    _loadPlayerPrefs();
    _loadCacheLimit();
    _loadPlaylists();
  }

  /// Carga las playlists (para el selector de recálculo de paletas).
  Future<void> _loadPlaylists() async {
    try {
      final db = context.read<AppDatabase>();
      final rows = await (db.select(
        db.playlists,
      )..orderBy([(p) => OrderingTerm.asc(p.name)])).get();
      if (!mounted) return;
      setState(() {
        _playlists = [
          for (final r in rows)
            Playlist(
              id: r.id,
              name: r.name,
              createdAt: r.createdAt,
              coverUrl: r.coverUrl,
              description: r.description,
              isFavorites: r.isFavorites,
            ),
        ];
        _selectedPlaylist ??= _playlists!.firstOrNull;
      });
    } catch (_) {}
  }

  /// Recalcula el trío (+ acento derivado) de cada portada distinta de la
  /// playlist seleccionada, con progreso visible.
  Future<void> _recalculatePalettes() async {
    final playlist = _selectedPlaylist;
    if (playlist == null || _recalculating) return;
    final db = context.read<AppDatabase>();
    final store = context.read<PaletteCacheStore>();
    setState(() {
      _recalculating = true;
      _recalcDone = 0;
      _recalcTotal = 0;
    });
    try {
      final urls = await db.distinctPlaylistArtworks(playlist.id);
      if (!mounted) return;
      setState(() => _recalcTotal = urls.length);
      var done = 0;
      for (final url in urls) {
        await ArtworkPaletteService.trioFor(
          url,
          store,
          force: true,
          artworkCache: context.read<ArtworkCacheService>(),
        );
        done++;
        if (mounted) setState(() => _recalcDone = done);
      }
    } catch (_) {
      // Best-effort: los fallos individuales ya se ignoran en el servicio.
    }
    if (mounted) setState(() => _recalculating = false);
  }

  /// Carga las preferencias del reproductor (karaoke + omitir silencios;
  /// best-effort).
  Future<void> _loadPlayerPrefs() async {
    try {
      final settings = context.read<SettingsStore>();
      final sweep = await settings.loadLyricsSweepEnabled();
      final skipSilence = await settings.loadSkipSilenceEnabled();
      if (!mounted) return;
      setState(() {
        _lyricsSweepEnabled = sweep;
        _skipSilenceEnabled = skipSilence;
      });
    } catch (_) {
      // La configuración nunca debe romper la vista.
    }
  }

  /// Carga el toggle de Discord guardado (best-effort).
  Future<void> _loadDiscordPrefs() async {
    try {
      final enabled = await context.read<SettingsStore>().loadDiscordEnabled();
      if (!mounted) return;
      setState(() => _discordEnabled = enabled);
    } catch (_) {
      // La configuración nunca debe romper la vista.
    }
  }

  Future<void> _loadCacheLimit() async {
    try {
      final mb = await context.read<SettingsStore>().loadCacheMaxSize();
      if (!mounted) return;
      setState(() => _cacheLimitMb = mb);
      // Aplicar el límite guardado al servicio de caché.
      if (mb != null) {
        context.read<AudioCacheService>().maxSizeBytes = mb * 1024 * 1024;
      }
    } catch (_) {}
  }

  Future<void> _setCacheLimit(int? mb) async {
    setState(() => _cacheLimitMb = mb);
    final settings = context.read<SettingsStore>();
    await settings.saveCacheMaxSize(mb);
    final cache = context.read<AudioCacheService>();
    cache.maxSizeBytes = mb != null
        ? mb * 1024 * 1024
        : AudioCacheService.defaultMaxSize;
    await _refreshStats();
  }

  String get _cacheLimitLabel {
    if (_cacheLimitMb == null)
      return _fmtBytes(AudioCacheService.defaultMaxSize);
    return _fmtBytes(_cacheLimitMb! * 1024 * 1024);
  }

  Future<void> _openCacheLimitMenu(BuildContext fieldContext) async {
    final box = fieldContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(fieldContext).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<int?>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 160, maxHeight: 380),
      clipBehavior: Clip.antiAlias,
      items: [
        for (final mb in _cacheLimitOptions)
          PopupMenuItem<int>(
            value: mb,
            child: Text(_fmtBytes(mb * 1024 * 1024)),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(value: -1, child: Text('Sin límite')),
      ],
    );
    if (selected == null || !mounted) return;
    await _setCacheLimit(selected == -1 ? null : selected);
  }

  Future<void> _refreshStats() async {
    final stats = await context.read<AudioCacheService>().stats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  Future<void> _clearCache() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.confirmClearCacheTitle),
        content: Text(l10n.confirmClearCacheBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.clearCache),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await context.read<AudioCacheService>().clear();
      if (!mounted) return;
      showScrupToast(l10n.cacheCleared, kind: ScrupToastKind.success);
    } catch (_) {
      // En Windows, el reproductor puede tener un archivo en uso y el borrado
      // fallar a mitad: se avisa pero no se rompe nada.
      if (!mounted) return;
      showScrupToast(l10n.cantClearCache, kind: ScrupToastKind.error);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    // Refrescar siempre: aunque falle, el estado real puede haber cambiado.
    await _refreshStats();
  }

  Future<void> _openCacheFolder() async {
    final cache = context.read<AudioCacheService>();
    final dir = await cache.cacheDir();
    final path = dir.path;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await Process.run('explorer', [path]);
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      await Process.run('xdg-open', [path]);
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      await Process.run('open', [path]);
    }
  }

  /// Formatea bytes en una unidad legible (B/KB/MB/GB, base 1024).
  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 'B';
    for (final u in units) {
      value /= 1024;
      unit = u;
      if (value < 1024) break;
    }
    final decimals = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} $unit';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final bool mobile = Binaries.isMobile;

    final Widget body = Material(
      color: Colors.transparent,
      child: ListView(
        // El contenedor ya termina por encima del player (margen
        // inferior), así que aquí solo hace falta un respiro pequeño.
        padding: EdgeInsets.fromLTRB(
          mobile ? 16 : 20,
          mobile ? 16 : 20,
          mobile ? 16 : 20,
          12,
        ),
        children: [
          // En móvil el título va en una caja de la MISMA altura que las
          // filas con botón de Inicio/Librería (48dp, centrada): así los
          // glifos quedan a la misma altura visual que esos títulos.
          mobile
              ? SizedBox(
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      AppLocalizations.of(context).settings,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                )
              : Text(
                  AppLocalizations.of(context).settings,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
          const SizedBox(height: 20),
          _buildLanguageSection(theme),
          SizedBox(height: mobile ? 8 : 16),
          _buildDiscordSection(theme),
          SizedBox(height: mobile ? 8 : 16),
          _buildPlayerSection(theme),
          SizedBox(height: mobile ? 8 : 16),
          _buildCacheSection(theme),
          SizedBox(height: mobile ? 8 : 16),
          // Los atajos de teclado no existen en Android: se ocultan.
          if (!mobile) _buildShortcutsSection(theme),
          if (!mobile) const SizedBox(height: 16),
          _buildAboutSection(theme),
        ],
      ),
    );

    if (mobile) return body;

    return Container(
      // Margen flotante + sombra exterior (fuera del clip). Top 12 =
      // alineado con el sidebar; bottom = kPlayerClearance para que el
      // contenedor termine POR ENCIMA del player con el MISMO hueco (12)
      // que lo separa del sidebar y del borde derecho (espaciado uniforme).
      margin: const EdgeInsets.fromLTRB(12, 12, 12, kPlayerClearance),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            // Plano: la MISMA receta del sidebar (un único tono oscuro),
            // sin tinte del acento — el degradado con acento queda solo para
            // el player.
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.72,
            ),
          ),
          child: body,
        ),
      ),
    );
  }

  /// Idioma: selector con todos los idiomas soportados (nombre mostrado en
  /// su propio idioma; persistido entre sesiones).
  Widget _buildLanguageSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final controller = context.watch<LocaleController>();
    return _SectionCard(
      icon: Icons.language_rounded,
      title: l10n.language,
      caption: l10n.languageHint,
      // Campo compacto RECTANGULAR (no ocupa todo el ancho de la tarjeta ni
      // es una píldora larga y fina): ancho fijo de 240px y el mismo radio de
      // esquinas redondeadas (14) que usan las tarjetas de sección. Abre un
      // menú propio vía showMenu en vez de un DropdownButton: así el hover
      // de los items queda full-bleed (el DropdownButton mete 8px fijos de
      // padding en su menú) y el campo no conserva el brillo de focus.
      child: Align(
        alignment: Alignment.centerLeft,
        child: Builder(
          // Semantics: el campo sustituye al DropdownButton, así que se le
          // da el rol de botón y el idioma activo como label accesible.
          builder: (fieldContext) => Semantics(
            button: true,
            label: _localeLabel(controller.locale),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              mouseCursor: SystemMouseCursors.click,
              // Sin brillo de focus persistente tras abrir el menú; el hover
              // es un destello sutil acorde al cristal.
              focusColor: Colors.transparent,
              hoverColor: Colors.white.withValues(alpha: 0.04),
              onTap: () => _openLanguageMenu(fieldContext),
              child: Container(
                width: Binaries.isMobile ? double.infinity : 240,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _localeLabel(controller.locale),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Abre el menú de idiomas ALINEADO con el campo (anclado a su rectángulo,
  /// con el mismo ancho) y con los mismos items full-bleed que los context
  /// menus: menuPadding cero + clip antiAlias para las esquinas redondeadas.
  Future<void> _openLanguageMenu(BuildContext fieldContext) async {
    final controller = context.read<LocaleController>();
    final box = fieldContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(fieldContext).context.findRenderObject()! as RenderBox;
    final locale = await showMenu<Locale>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      // Mismo ancho que el campo y altura tope para que, si en el futuro
      // hay más idiomas de los que caben, el menú haga scroll (con showMenu
      // sin maxHeight crecería hasta desbordar la ventana).
      constraints: const BoxConstraints(minWidth: 240, maxHeight: 380),
      clipBehavior: Clip.antiAlias,
      items: [
        for (final option in _localeOptions)
          PopupMenuItem<Locale>(
            value: option.locale,
            child: Text(option.label),
          ),
      ],
    );
    if (locale == null || !mounted) return;
    final settings = context.read<SettingsStore>();
    unawaited(controller.setLocale(locale, settings));
  }

  /// Nombre mostrado del idioma activo (para el campo del selector).
  String _localeLabel(Locale locale) {
    for (final option in _localeOptions) {
      if (option.locale == locale) return option.label;
    }
    return locale.toString();
  }

  /// Discord: activa la presencia de Rich Presence. El id de aplicación de
  /// Scrup está embebido en el cliente: funciona de fábrica, solo hay que
  /// tener Discord abierto y darle al interruptor.
  Widget _buildDiscordSection(ThemeData theme) {
    // Discord Rich Presence is desktop-only (local IPC over named pipes /
    // XDG_RUNTIME_DIR sockets); not available on mobile.
    if (!Binaries.isDesktop) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final service = context.read<DiscordPresenceService>();

    return _SectionCard(
      icon: Icons.headphones_rounded,
      title: l10n.discordPresence,
      caption: l10n.discordPresenceHint,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            tileColor: Colors.transparent,
            title: SizedBox(
              width: Binaries.isMobile ? null : 240,
              child: Text(
                l10n.discordEnabled,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            value: _discordEnabled,
            onChanged: (value) async {
              setState(() => _discordEnabled = value);
              await service.setEnabled(value);
            },
          ),
          Padding(
            padding: EdgeInsets.only(top: 8, left: Binaries.isMobile ? 0 : 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: service.connected,
              builder: (context, connected, _) => Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected ? 'Conectado' : 'Desconectado',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: connected
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Lyrics: modo karaoke (sweep palabra por palabra).
  Widget _buildPlayerSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final settings = context.read<SettingsStore>();

    return _SectionCard(
      icon: Icons.lyrics_rounded,
      title: l10n.lyrics,
      caption: l10n.syncLyricsTitle,
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            tileColor: Colors.transparent,
            title: SizedBox(
              width: Binaries.isMobile ? null : 240,
              child: Text(
                l10n.karaokeSweep,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            subtitle: Text(
              l10n.karaokeSweepHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: _lyricsSweepEnabled,
            onChanged: (value) async {
              setState(() => _lyricsSweepEnabled = value);
              await settings.setLyricsSweepEnabled(value);
            },
          ),
          // Silence-skip analyzes the local file with an ffmpeg subprocess
          // (desktop only; no ffmpeg toolchain on mobile).
          if (Binaries.isDesktop)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              tileColor: Colors.transparent,
              title: SizedBox(
                width: Binaries.isMobile ? null : 240,
                child: Text(
                  l10n.skipSilence,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              subtitle: Text(
                l10n.skipSilenceHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              value: _skipSilenceEnabled,
              onChanged: (value) async {
                setState(() => _skipSilenceEnabled = value);
                await settings.setSkipSilenceEnabled(value);
              },
            ),
        ],
      ),
    );
  }

  /// Caché: tamaño usado (del límite) + nº de archivos + vaciar.
  Widget _buildCacheSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final cache = context.read<AudioCacheService>();
    final stats = _stats;
    final muted = theme.colorScheme.onSurfaceVariant;

    return _SectionCard(
      icon: Icons.sd_storage_rounded,
      title: l10n.cache,
      caption: l10n.cacheHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              if (stats == null)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else ...[
                Text(
                  l10n.cacheUsed(
                    _fmtBytes(stats.bytes),
                    _fmtBytes(cache.maxSizeBytes),
                  ),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· ${l10n.cacheFiles(stats.fileCount)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          // Límite del caché: selector con presets.
          Text(
            l10n.cacheLimit,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (fieldContext) => InkWell(
              borderRadius: BorderRadius.circular(14),
              mouseCursor: SystemMouseCursors.click,
              focusColor: Colors.transparent,
              hoverColor: Colors.white.withValues(alpha: 0.04),
              onTap: () => _openCacheLimitMenu(fieldContext),
              child: Container(
                width: Binaries.isMobile ? double.infinity : 240,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _cacheLimitLabel,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _refreshStats,
                style: FilledButton.styleFrom().copyWith(
                  mouseCursor: WidgetStateProperty.all(
                    SystemMouseCursors.click,
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.refresh),
              ),
              FilledButton.icon(
                onPressed: _openCacheFolder,
                style: FilledButton.styleFrom().copyWith(
                  mouseCursor: WidgetStateProperty.all(
                    SystemMouseCursors.click,
                  ),
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(l10n.openFolder),
              ),
              FilledButton.icon(
                onPressed: _clearing ? null : _clearCache,
                style:
                    FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ).copyWith(
                      mouseCursor: WidgetStateProperty.all(
                        SystemMouseCursors.click,
                      ),
                    ),
                icon: _clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_rounded, size: 18),
                label: Text(l10n.clearCache),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Colores de portadas (mismo dominio de caché): trío fullscreen
          // + acento derivado, con recálculo manual por playlist.
          ..._buildPaletteControls(theme),
        ],
      ),
    );
  }

  /// Acerca de: nombre y versión de la app.
  /// Controles de PALETAS (embebidos en la card de caché): cuántas
  /// portadas tienen colores calculados (trío fullscreen + acento derivado)
  /// y recálculo manual por playlist con progreso.
  List<Widget> _buildPaletteControls(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final db = context.read<AppDatabase>();
    final muted = theme.colorScheme.onSurfaceVariant;

    return [
      Row(
        children: [
          const Icon(Icons.palette_rounded, size: 20),
          const SizedBox(width: 8),
          Text(
            l10n.paletteCacheTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        l10n.paletteCacheHint,
        style: theme.textTheme.bodySmall?.copyWith(color: muted),
      ),
      const SizedBox(height: 14),
      FutureBuilder<int>(
        future: db.allPalettes().then((r) => r.length),
        builder: (context, snap) {
          final n = snap.data;
          return Text(
            n == null ? '…' : l10n.paletteCacheEntries(n),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          );
        },
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: Builder(
              builder: (fieldContext) => InkWell(
                borderRadius: BorderRadius.circular(14),
                mouseCursor: SystemMouseCursors.click,
                focusColor: Colors.transparent,
                hoverColor: Colors.white.withValues(alpha: 0.04),
                onTap: _recalculating
                    ? null
                    : () => _openPlaylistMenu(fieldContext),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.35,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedPlaylist?.name ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const Icon(Icons.expand_more_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: (_recalculating || _selectedPlaylist == null)
                ? null
                : _recalculatePalettes,
            style: FilledButton.styleFrom().copyWith(
              mouseCursor: WidgetStateProperty.all(SystemMouseCursors.click),
            ),
            icon: _recalculating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
            label: Text(l10n.paletteRecalc),
          ),
        ],
      ),
      if (_recalculating) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: _recalcTotal == 0 ? null : _recalcDone / _recalcTotal,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 6),
        Text(
          '$_recalcDone / $_recalcTotal',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    ];
  }

  /// Menú del selector de playlist (mismo patrón que el de idioma).
  Future<void> _openPlaylistMenu(BuildContext fieldContext) async {
    final box = fieldContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(fieldContext).context.findRenderObject()! as RenderBox;
    final playlist = await showMenu<Playlist>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 240, maxHeight: 380),
      clipBehavior: Clip.antiAlias,
      items: [
        for (final p in _playlists ?? const <Playlist>[])
          PopupMenuItem<Playlist>(
            value: p,
            height: 44,
            child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
    if (playlist == null || !mounted) return;
    setState(() => _selectedPlaylist = playlist);
  }

  Widget _buildShortcutsSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final labels = <String, String>{
      '_playPause': l10n.shortcutPlayPause,
      '_next': l10n.shortcutNext,
      '_previous': l10n.shortcutPrevious,
      '_seekForward': l10n.shortcutSeekForward,
      '_seekBackward': l10n.shortcutSeekBackward,
      '_volumeUp': l10n.shortcutVolumeUp,
      '_volumeDown': l10n.shortcutVolumeDown,
      '_mute': l10n.shortcutMute,
      '_toggleLyrics': l10n.shortcutToggleLyrics,
      '_toggleQueue': l10n.shortcutToggleQueue,
      '_toggleSettings': l10n.shortcutToggleSettings,
      '_closePanel': l10n.shortcutClosePanel,
      '_fullscreen': l10n.shortcutFullscreen,
      '_toggleShuffle': l10n.shortcutToggleShuffle,
      '_toggleRepeat': l10n.shortcutToggleRepeat,
      '_toggleRadio': l10n.shortcutToggleRadio,
      '_toggleFavorite': l10n.shortcutToggleFavorite,
      '_mouseBack': l10n.shortcutMouseBack,
      '_mouseForward': l10n.shortcutMouseForward,
    };

    // Categorías con sus atajos.
    final categories = <(String, List<(String, String)>)>[
      (
        l10n.shortcutCategoryPlayback,
        [
          ('Space', '_playPause'),
          ('N', '_next'),
          ('P', '_previous'),
          ('→', '_seekForward'),
          ('←', '_seekBackward'),
          ('🖱️ ⏴', '_mouseBack'),
          ('🖱️ ⏵', '_mouseForward'),
          ('F', '_toggleFavorite'),
        ],
      ),
      (
        l10n.shortcutCategoryVolume,
        [('↑', '_volumeUp'), ('↓', '_volumeDown'), ('M', '_mute')],
      ),
      (
        l10n.shortcutCategoryNavigation,
        [
          ('L', '_toggleLyrics'),
          ('Q', '_toggleQueue'),
          (',', '_toggleSettings'),
          ('Esc', '_closePanel'),
          ('F11', '_fullscreen'),
        ],
      ),
      (
        l10n.shortcutCategoryModes,
        [
          ('S', '_toggleShuffle'),
          ('R', '_toggleRepeat'),
          ('D', '_toggleRadio'),
        ],
      ),
    ];

    return _SectionCard(
      icon: Icons.keyboard_rounded,
      title: l10n.keyboardShortcuts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cat in categories) ...[
            // Título de categoría
            Padding(
              padding: const EdgeInsets.only(bottom: 4, top: 2),
              child: Text(
                cat.$1,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Atajos de esta categoría
            for (final entry in cat.$2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Text(
                        entry.$1,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: muted.withValues(alpha: 0.2),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      labels[entry.$2] ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildAboutSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    return _SectionCard(
      icon: Icons.info_rounded,
      title: l10n.about,
      child: Row(
        children: [
          Text(
            l10n.version,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            kAppVersionFull,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opción de idioma del selector: el [Locale] y su nombre en su propio idioma.
class _LocaleOption {
  final Locale locale;
  final String label;

  const _LocaleOption(this.locale, this.label);
}

/// Tarjeta/sección de ajustes. En desktop es un fondo sutil redondeado; en
/// móvil se elimina el contenedor (la sección ocupa todo el ancho) y las
/// categorías se separan con una línea divisoria.
class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? caption;
  final Widget child;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(
            caption!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        child,
      ],
    );

    if (Binaries.isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          content,
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.18),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.5),
      ),
      child: content,
    );
  }
}
