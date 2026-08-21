import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/discord/discord_presence_service.dart';
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

  /// Estado de la presencia de Discord (cargado desde el store al abrir).
  bool _discordEnabled = false;

  /// Modo karaoke (sweep palabra por palabra) de los lyrics.
  bool _lyricsSweepEnabled = false;

  /// Omitir silencios (saltar huecos sin música automáticamente).
  bool _skipSilenceEnabled = true;

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
            // Plano: la MISMA receta del sidebar (dos tonos oscuros en
            // degradado VERTICAL con contraste suave), sin tinte del acento
            // — el degradado con acento queda solo para el player.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.72,
                ),
                theme.colorScheme.surfaceContainer.withValues(alpha: 0.45),
              ],
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: ListView(
              // El contenedor ya termina por encima del player (margen
              // inferior), así que aquí solo hace falta un respiro pequeño.
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              children: [
                Text(
                  AppLocalizations.of(context).settings,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                _buildLanguageSection(theme),
                const SizedBox(height: 16),
                _buildDiscordSection(theme),
                const SizedBox(height: 16),
                _buildPlayerSection(theme),
                const SizedBox(height: 16),
                _buildCacheSection(theme),
                const SizedBox(height: 16),
                _buildAboutSection(theme),
              ],
            ),
          ),
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
      icon: Icons.language,
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
              // Sin brillo de focus persistente tras abrir el menú; el hover
              // es un destello sutil acorde al cristal.
              focusColor: Colors.transparent,
              hoverColor: Colors.white.withValues(alpha: 0.04),
              onTap: () => _openLanguageMenu(fieldContext),
              child: Container(
                width: 240,
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
              width: 240,
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
            padding: const EdgeInsets.only(top: 8, left: 16),
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
      icon: Icons.lyrics_outlined,
      title: l10n.lyrics,
      caption: l10n.syncLyricsTitle,
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            tileColor: Colors.transparent,
            title: SizedBox(
              width: 240,
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            tileColor: Colors.transparent,
            title: SizedBox(
              width: 240,
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
      icon: Icons.sd_storage_outlined,
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
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _refreshStats,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.refresh),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _clearing ? null : _clearCache,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: _clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_outlined, size: 18),
                label: Text(l10n.clearCache),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Acerca de: nombre y versión de la app.
  Widget _buildAboutSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    return _SectionCard(
      icon: Icons.info_outline,
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
            '1.0.0',
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

/// Tarjeta de sección: fondo sutil redondeado con icono, título y caption.
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.5),
      ),
      child: Column(
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
      ),
    );
  }
}
