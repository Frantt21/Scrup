import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/audio_cache_service.dart';
import 'scrup_toasts.dart';

/// Diálogo de descargas de settings: tabs (pills) por playlist con el
/// espacio usado por las canciones descargadas de cada una, más la pestaña
/// "Todas". Cada fila se puede eliminar individualmente (con confirmación).
///
/// Abre AL INSTANTE (el constructor solo recibe servicios) y carga sus
/// datos dentro con spinner: la lista de archivos + backfill de metadata
/// nunca bloquea la apertura. La agrupación es por MEMBRESÍA (la canción
/// aparece en cada playlist que la contenga) y el borrado es del ARCHIVO
/// de caché — la pista sigue en la playlist y vuelve a descargarse al
/// reproducirla.
class DownloadsDialog extends StatefulWidget {
  const DownloadsDialog({super.key, required this.db, required this.cache});

  final AppDatabase db;
  final AudioCacheService cache;

  @override
  State<DownloadsDialog> createState() => _DownloadsDialogState();
}

class _DownloadsDialogState extends State<DownloadsDialog> {
  static const int _allTab = -1;
  int _selectedTabId = _allTab;


  Future<_TabsData>? _tabsFuture;

  // Resolución de artworks en caliente: memo url → FileImage decodificado.
  // El listado vive en un ListView virtualizado: al scrollear cada fila que
  // entra se remonta y CoverImage vuelve a resolver el path (exists+touch
  // por URL, I/O síncrono en el UI thread del diálogo). Con cientos de
  // filas eso congela el drag del scrollbar. Con el memo, cada URL se
  // resuelve UNA vez por sesión y el provider queda en el cache de imágenes
  // de Flutter (re-decode cero al re-aparecer la fila).
  final Map<String, ImageProvider> _imageMemo = {};

  ImageProvider? _imageFor(String? url) {
    if (url == null || url.isEmpty) return null;
    final hit = _imageMemo[url];
    if (hit != null) return hit;
    // FileImage con ResizeImage: la decodificación queda registrada en el
    // cache de imágenes incluso antes del primer paint (precache en el
    // futuro), y a 96px pesa una fracción del original en GPU.
    final provider = ResizeImage(
      FileImage(File(url)),
      width: 96,
      height: 96,
      policy: ResizeImagePolicy.exact,
    );
    _imageMemo[url] = provider;
    return provider;
  }

  void _reload() {
    // El trabajo async va FUERA del setState: si el callback devuelve un
    // Future, el assert del framework lanza antes de markNeedsBuild() y el
    // FutureBuilder nunca recibe el nuevo future (diálogo vacío eterno).
    final future = _buildTabs();
    setState(() {
      _tabsFuture = future;
    });
  }

  Future<void> _confirmAndDelete(CachedTrackFile file, String name) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.deleteDownloadConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.cache.deleteCachedTrack(file.videoId);
    if (!mounted) return;
    showScrupToast(l10n.delete, kind: ScrupToastKind.success);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.downloadsDialogTitle),
      content: SizedBox(
        width: 520,
        height: 480,
        child: FutureBuilder<_TabsData>(
          future: _tabsFuture,
          builder: (context, snap) {
            // Un fallo de datos se muestra como lista vacía, nunca como
            // spinner eterno.
            final tabs = snap.data;
            if (tabs == null) {
              if (snap.hasError ||
                  snap.connectionState != ConnectionState.waiting) {
                return Center(
                  child: Text(
                    l10n.downloadsEmpty,
                    style: theme.textTheme.bodyMedium,
                  ),
                );
              }
              return const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final active = tabs.byId[_selectedTabId] ?? tabs.all;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tabs como pills (Wrap: en angostas bajan de línea).
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tab in tabs.list)
                      _Pill(
                        tab: tab,
                        selected: active == tab,
                        onTap: () => setState(() => _selectedTabId = tab.id),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (active.files.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        l10n.downloadsEmpty,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: active.files.length,
                      itemBuilder: (context, i) {
                        final file = active.files[i];
                        final meta = tabs.meta[file.videoId];
                        final title = (meta?.title.isNotEmpty ?? false)
                            ? meta!.title
                            : file.videoId;
                        return ListTile(
                          // ListTile sobre un DecoratedBox con color lanza
                          // el assert "ink splashes may be invisible" y el
                          // framework tumba el build: los datos cargados no
                          // se llegan a pintar ("se perdieron las
                          // descargas").
                          tileColor: Colors.transparent,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              // Artwork vía provider MEMOIZADO (ver
                              // _imageFor): sin I/O por remount de fila —
                              // el drag del scrollbar no se congela.
                              // gaplessPlayback: al re-entrar la fila el
                              // provider ya está en el cache de imágenes,
                              // no hay flash del fallback.
                              child: _ArtThumb(
                                provider: _imageFor(meta?.thumbnailUrl),
                                iconColor: theme.colorScheme.onSurfaceVariant,
                                boxColor: theme.colorScheme.surfaceContainerHigh,
                              ),
                            ),
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: (meta?.artist.isEmpty ?? true)
                              ? null
                              : Text(
                                  meta!.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _fmtBytes(file.sizeBytes),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                ),
                                tooltip: l10n.delete,
                                onPressed: () => _confirmAndDelete(file, title),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                // Footer: nº de canciones y total de la pestaña activa.
                const SizedBox(height: 8),
                Text(
                  '${active.files.length} · ${_fmtBytes(active.totalBytes)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    );
  }

  Future<_TabsData> _buildTabs() async {
    final l10n = AppLocalizations.of(context);
    // Cada capa degrada por separado: si la DB falla, el diálogo igual
    // lista los archivos pelados (videoId + tamaño) en "Todas". Jamás
    // queda vacío con archivos en disco.
    List<CachedTrackFile>? files;
    Map<String, CachedTrackRow> meta = const {};
    List<Playlist> playlists = const [];
    final membership = <String, Set<int>>{};
    try {
      files = await widget.cache.cachedTracks();
    } catch (e) {
      debugPrint('[downloads] cachedTracks falló: $e');
    }
    try {
      playlists = await widget.db.watchPlaylists().first;
      final allCached = await widget.db.allCachedTracks();
      meta = {for (final r in allCached) r.id: r};
      for (final pl in playlists) {
        final ids = await widget.db.playlistTrackIds(pl.id);
        for (final t in ids) {
          membership.putIfAbsent(t, () => {}).add(pl.id);
        }
      }
    } catch (e) {
      debugPrint('[downloads] DB falló: $e');
    }
    final list = files ?? const <CachedTrackFile>[];

    final all = _TabData(
      id: _allTab,
      label: l10n.downloadsAll,
      files: List.of(list),
    );

    // Una pestaña por playlist con al menos una canción descargada.
    final tabs = <_TabData>[all];
    final byId = {for (final t in list) t.videoId: t};
    for (final pl in playlists) {
      final plFiles = <CachedTrackFile>[];
      final seen = <String>{};
      for (final entry in membership.entries) {
        if (!entry.value.contains(pl.id)) continue;
        final f = byId[entry.key];
        if (f == null || !seen.add(f.videoId)) continue;
        plFiles.add(f);
      }
      if (plFiles.isEmpty) continue;
      tabs.add(_TabData(id: pl.id, label: pl.name, files: plFiles));
    }

    // Precache de TODOS los artworks visibles (96px, batch): al scrollear,
    // las filas que entran encuentran el decode hecho — sin I/O ni jank en
    // el drag. Falla silenciosa: sin cache el errorBuilder pinta el
    // placeholder. Se hace solo si el diálogo sigue montado (después de los
    // awaits del pipeline).
    if (!mounted) return _TabsData(list: tabs, all: all, meta: meta);
    try {
      for (final r in meta.values) {
        final path = r.thumbnailUrl;
        if (path == null || path.isEmpty) continue;
        final provider = _imageFor(path);
        if (provider != null) {
          precacheImage(provider, context).catchError((_) {});
        }
      }
    } catch (_) {}

    return _TabsData(list: tabs, all: all, meta: meta);
  }
}

/// Artwork de una fila: pinta el provider si existe, o el placeholder de
/// nota musical. Sin CoverImage (I/O de resolución por remount) y sin
/// MemoryImage vacía (decoder fallaría en cada intento).
class _ArtThumb extends StatelessWidget {
  const _ArtThumb({
    required this.provider,
    required this.iconColor,
    required this.boxColor,
  });
  final ImageProvider? provider;
  final Color iconColor;
  final Color boxColor;

  @override
  Widget build(BuildContext context) {
    final p = provider;
    if (p == null) {
      return ColoredBox(
        color: boxColor,
        child: Icon(
          Icons.music_note_rounded,
          size: 20,
          color: iconColor,
        ),
      );
    }
    return Image(
      image: p,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => ColoredBox(
        color: boxColor,
        child: Icon(Icons.music_note_rounded, size: 20, color: iconColor),
      ),
    );
  }
}

class _TabsData {
  const _TabsData({
    required this.list,
    required this.all,
    required this.meta,
  });
  final List<_TabData> list;
  final _TabData all;
  final Map<String, CachedTrackRow> meta;

  Map<int, _TabData> get byId => {for (final t in list) t.id: t};
}

class _TabData {
  const _TabData({required this.id, required this.label, required this.files});
  final int id;
  final String label;
  final List<CachedTrackFile> files;
  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);
}

class _Pill extends StatelessWidget {
  const _Pill({required this.tab, required this.selected, required this.onTap});
  final _TabData tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tab.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _fmtBytes(tab.totalBytes),
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary.withValues(alpha: 0.8)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
