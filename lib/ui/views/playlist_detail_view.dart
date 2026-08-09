import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../services/playlist_cover_store.dart';
import '../playback.dart';
import '../theme_controller.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;
import '../widgets/scrup_snackbar.dart';
import '../widgets/track_tile.dart';

/// Detalle de una playlist renderizado EN EL MISMO espacio (sin abrir rutas):
/// cabecera de presentación con la portada grande, el título a la derecha,
/// una descripción editable y un ambiente teñido con el color del artwork;
/// debajo, la lista de canciones con reproducción individual o en cola.
class PlaylistDetailView extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onBack;

  const PlaylistDetailView({
    super.key,
    required this.playlist,
    required this.onBack,
  });

  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  late final Stream<List<Track>> _tracksStream;
  late final Stream<Playlist?> _playlistStream;
  StreamSubscription<List<Track>>? _tracksSub;
  StreamSubscription<Playlist?>? _playlistSub;
  List<Track> _tracks = const [];

  /// Playlist en vivo (portada/descripción pueden cambiar desde este detalle).
  Playlist? _playlist;

  /// Color de ambiente extraído de la portada (para el degradado del hero y
  /// como `primary` del detalle: botones y elementos usan el color de la
  /// PLAYLIST, no el de la canción en reproducción).
  Color? _ambientColor;
  String? _ambientFor;
  int _ambientToken = 0;

  /// Caché de color extraído por portada, compartida entre instancias del
  /// detalle: evita re-descargar/re-analizar la misma portada en la sesión
  /// (también cachea los fallos con `null` para no reintentar).
  static final Map<String, Color?> _paletteCache = {};

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDatabase>();
    _playlist = widget.playlist;
    _playlistStream = db.watchPlaylist(widget.playlist.id);
    _playlistSub = _playlistStream.listen((p) {
      if (!mounted) return;
      setState(() {
        if (p != null) _playlist = p;
      });
      if (p != null) _maybeExtractAmbient(p.coverUrl);
    });
    _tracksStream = db.watchPlaylistTracks(widget.playlist.id);
    _tracksSub = _tracksStream.listen((tracks) {
      if (!mounted) return;
      setState(() => _tracks = tracks);
    });
    _maybeExtractAmbient(widget.playlist.coverUrl);
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    _playlistSub?.cancel();
    super.dispose();
  }

  /// Extrae el color ambiente de la portada solo cuando esta cambia (evita
  /// re-analizar en cada rebuild) y usa el caché de la sesión cuando existe.
  void _maybeExtractAmbient(String? coverUrl) {
    if (coverUrl == null || coverUrl == _ambientFor) return;
    _ambientFor = coverUrl;
    if (_paletteCache.containsKey(coverUrl)) {
      setState(() => _ambientColor = _paletteCache[coverUrl]);
      return;
    }
    // Limpiar el color viejo de inmediato (si lo hay) para que el hero no
    // muestre el ambiente de la portada anterior mientras se extrae el nuevo.
    // El guard evita setState durante initState (allí el color ya es null).
    if (_ambientColor != null) {
      setState(() => _ambientColor = null);
    }
    final token = ++_ambientToken;
    unawaited(_extractAmbient(coverUrl, token));
  }

  Future<void> _extractAmbient(String source, int token) async {
    Color? color;
    try {
      final bytes = CoverImage.isLocalPath(source)
          ? await File(source).readAsBytes()
          : (await http
                    .get(
                      Uri.parse(source),
                      headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
                    )
                    .timeout(const Duration(seconds: 10)))
                .bodyBytes;
      final palette = await PaletteGenerator.fromImageProvider(
        MemoryImage(bytes),
        maximumColorCount: 16,
      );
      color = ThemeController.pickAccent(palette);
    } catch (_) {
      color = null;
    }
    // Guardar también los fallos (null) para no reintentar la misma portada.
    _paletteCache[source] = color;
    if (!mounted || token != _ambientToken) return;
    setState(() => _ambientColor = color);
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    // Reproduce toda la playlist como cola (auto-advance al terminar).
    await playQueue(context, _tracks);
  }

  Future<void> _removeTrack(Track track) async {
    await context.read<AppDatabase>().removeFromPlaylist(
      widget.playlist.id,
      track.id,
    );
  }

  /// Editor de descripción (dialog simple con texto multilínea).
  Future<void> _editDescription() async {
    final controller = TextEditingController(
      text: _playlist?.description ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Descripción'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 300,
          decoration: const InputDecoration(
            hintText: '¿De qué trata esta playlist?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final description = result.isEmpty ? null : result;
    await context.read<AppDatabase>().setPlaylistDescription(
      widget.playlist.id,
      description,
    );
  }

  /// Selector de portada: elegir una imagen desde los archivos del usuario,
  /// el artwork de una de las canciones de la playlist, o quitar la portada.
  Future<void> _pickCover() async {
    final db = context.read<AppDatabase>();
    final choice =
        await showModalBottomSheet<({String? url, bool remove, bool fromFile})>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Portada de la playlist',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('Elegir desde archivo…'),
                  onTap: () => Navigator.pop(ctx, (
                    url: null,
                    remove: false,
                    fromFile: true,
                  )),
                ),
                if (_tracks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      'Añade canciones para poder usar su portada como la de la '
                      'playlist.',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final track in _tracks.take(12))
                  ListTile(
                    dense: true,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: CoverImage(
                          source: track.thumbnailUrl,
                          fallback: _artworkFallback(Theme.of(ctx)),
                        ),
                      ),
                    ),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(ctx, (
                      url: track.thumbnailUrl,
                      remove: false,
                      fromFile: false,
                    )),
                  ),
                if (_playlist?.coverUrl != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Quitar portada'),
                    onTap: () => Navigator.pop(ctx, (
                      url: null,
                      remove: true,
                      fromFile: false,
                    )),
                  ),
              ],
            ),
          ),
        );
    if (choice == null) return;
    if (choice.fromFile) {
      await _pickCoverFromFile();
    } else if (choice.remove) {
      await db.setPlaylistCover(widget.playlist.id, null);
    } else {
      await db.setPlaylistCover(widget.playlist.id, choice.url);
    }
  }

  /// Copia una imagen elegida por el usuario al directorio de portadas de la
  /// app y la asigna a la playlist. Copiar (en vez de referenciar el archivo
  /// original) hace que la portada sobreviva aunque el usuario mueva el
  /// archivo original.
  Future<void> _pickCoverFromFile() async {
    const images = XTypeGroup(
      label: 'Imágenes',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final db = context.read<AppDatabase>();
    try {
      final current = await db.getPlaylist(widget.playlist.id);
      final currentCover = current?.coverUrl;
      final dest = await copyPlaylistCoverToAppDir(
        widget.playlist.id,
        file.path,
      );
      if (p.equals(file.path, dest)) {
        // El archivo elegido ya es la portada actual.
        if (!mounted) return;
        showScrupSnackBar(messenger, 'Esa imagen ya es la portada');
        return;
      }
      // copyPlaylistCoverToAppDir ya copió el archivo al destino. Si el copy
      // falla, la portada anterior se conserva; solo después limpiamos la
      // portada local anterior para no acumular huérfanos.
      await db.setPlaylistCover(widget.playlist.id, dest);
      if (currentCover != null &&
          CoverImage.isLocalPath(currentCover) &&
          !p.equals(currentCover, dest)) {
        final old = File(currentCover);
        if (await old.exists()) await old.delete();
      }
      if (!mounted) return;
      showScrupSnackBar(messenger, 'Portada actualizada');
    } catch (_) {
      if (!mounted) return;
      showScrupSnackBar(messenger, 'No se pudo usar esa imagen');
    }
  }

  Widget _artworkFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _coverArt(ThemeData theme, String? url) {
    return CoverImage(
      source: url,
      cacheWidth: 400,
      fallback: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surfaceContainerHigh,
              theme.colorScheme.surfaceContainer,
            ],
          ),
        ),
        child: Icon(
          Icons.queue_music,
          size: 40,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  /// Deriva un tema con el color de la portada como `primary` (y un
  /// `onPrimary` con contraste legible), en lugar del acento de la canción
  /// actual.
  ThemeData _themeWithPlaylistColor(ThemeData base, Color color) {
    final onPrimary =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: color,
        onPrimary: onPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final playlistColor = _ambientColor;
    // Mientras se ve la playlist, los botones y elementos usan el color de
    // SU portada (no el acento de la canción en reproducción).
    final theme = playlistColor != null
        ? _themeWithPlaylistColor(baseTheme, playlistColor)
        : baseTheme;
    final playlist = _playlist ?? widget.playlist;
    final count = _tracks.length;
    final ambient = _ambientColor;

    return Theme(
      data: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero de presentación: ambiente del artwork + portada grande +
          // título a la derecha + descripción + acciones.
          Container(
            decoration: BoxDecoration(
              // Ambiente: el degradado se tiñe con el color extraído de la
              // portada y se desvanece hacia abajo sobre el negro.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ambient?.withValues(alpha: 0.30) ?? Colors.transparent,
                  Colors.transparent,
                ],
                stops: const [0.0, 1.0],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Volver a playlists',
                    onPressed: widget.onBack,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Portada grande
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 160,
                          height: 160,
                          child: _coverArt(theme, playlist.coverUrl),
                        ),
                      ),
                      const SizedBox(width: 24),
                      // Título + metadatos + descripción + acciones
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              playlist.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$count '
                              '${count == 1 ? 'canción' : 'canciones'}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (playlist.description != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                playlist.description!,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: _tracks.isEmpty ? null : _playAll,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('Reproducir'),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.photo_library_outlined,
                                  ),
                                  tooltip: 'Portada de la playlist',
                                  onPressed: _pickCover,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.notes_rounded),
                                  tooltip: playlist.description == null
                                      ? 'Añadir descripción'
                                      : 'Editar descripción',
                                  onPressed: _editDescription,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _tracks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.music_off,
                          size: 64,
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Playlist vacía',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Añade canciones desde la búsqueda',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    // El player flotante cubre la parte inferior: dejar espacio
                    // para que la última canción quede accesible.
                    padding: const EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      kPlayerOverlayInset,
                    ),
                    itemCount: _tracks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final track = _tracks[i];
                      return TrackTile(
                        track: track,
                        onPlay: () => playTrack(context, track),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Quitar de la playlist',
                          onPressed: () => _removeTrack(track),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
