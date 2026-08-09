import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import '../../services/settings_store.dart';
import '../locale_controller.dart';
import '../theme_controller.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;
import '../widgets/scrup_snackbar.dart';

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

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    final stats = await context.read<AudioCacheService>().stats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  Future<void> _clearCache() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
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
      showScrupSnackBar(messenger, l10n.cacheCleared);
    } catch (_) {
      // En Windows, el reproductor puede tener un archivo en uso y el borrado
      // fallar a mitad: se avisa pero no se rompe nada.
      if (!mounted) return;
      showScrupSnackBar(messenger, l10n.cantClearCache);
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
    final themeController = context.watch<ThemeController>();
    final base = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.55,
    );

    return Container(
      // Margen flotante + sombra exterior (fuera del clip). Top 12 =
      // alineado con el sidebar; bottom = kPlayerOverlayInset para que el
      // contenedor termine POR ENCIMA del player (separado, sin pasar por
      // detrás).
      margin: const EdgeInsets.fromLTRB(12, 12, 12, kPlayerOverlayInset),
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
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  themeController.accentColor?.withValues(alpha: 0.20) ?? base,
                  base,
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
                  _buildCacheSection(theme),
                  const SizedBox(height: 16),
                  _buildAboutSection(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Idioma: selector Español / English (persistido entre sesiones).
  Widget _buildLanguageSection(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final controller = context.watch<LocaleController>();
    return _SectionCard(
      icon: Icons.language,
      title: l10n.language,
      caption: l10n.languageHint,
      child: SegmentedButton<Locale>(
        segments: const [
          ButtonSegment(value: Locale('es'), label: Text('Español')),
          ButtonSegment(value: Locale('en'), label: Text('English')),
        ],
        selected: {controller.locale},
        onSelectionChanged: (selection) {
          final locale = selection.first;
          final settings = context.read<SettingsStore>();
          unawaited(controller.setLocale(locale, settings));
        },
        showSelectedIcon: false,
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
            '0.1.0',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
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
