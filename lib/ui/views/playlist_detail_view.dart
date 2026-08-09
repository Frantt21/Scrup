import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../data/database.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/player_service.dart';
import '../playback.dart';
import '../theme_controller.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerOverlayInset;
import '../widgets/scrup_snackbar.dart';
import '../widgets/track_tile.dart';

/// Detalle de una playlist como CONTENEDOR FLOTANTE tipo glass (márgenes,
/// blur y sombra, como el sidebar/player), renderizado EN EL MISMO espacio
/// sin abrir rutas. El botón de volver vive en la title bar del app. La
/// portada muestra acciones de edición al hacer hover y las canciones tienen
/// menú contextual con clic derecho.
class PlaylistDetailView extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onBack;

  /// Se llama tras editar la playlist (p. ej. renombrarla) para que el
  /// padre actualice su copia y la title bar muestre el nombre nuevo.
  final ValueChanged<Playlist>? onUpdated;

  const PlaylistDetailView({
    super.key,
    required this.playlist,
    required this.onBack,
    this.onUpdated,
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

  /// Playlist en vivo (portada/descripción/nombre pueden cambiar aquí).
  Playlist? _playlist;

  /// Color de la portada (para el degradado del hero, el tinte del cristal y
  /// como `primary` del detalle: botones y elementos usan el color de la
  /// PLAYLIST, no el de la canción en reproducción).
  Color? _ambientColor;
  String? _ambientFor;
  int _ambientToken = 0;

  /// Caché de color extraído por portada, compartida entre instancias del
  /// detalle: evita re-descargar/re-analizar la misma portada en la sesión.
  static final Map<String, Color?> _paletteCache = {};

  /// Hover sobre la portada (muestra las acciones de edición).
  bool _coverHovered = false;

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

  /// Extrae el color de la portada solo cuando cambia (evita re-analizar en
  /// cada rebuild) y usa el caché de la sesión cuando existe.
  void _maybeExtractAmbient(String? coverUrl) {
    if (coverUrl == null || coverUrl == _ambientFor) return;
    _ambientFor = coverUrl;
    if (_paletteCache.containsKey(coverUrl)) {
      setState(() => _ambientColor = _paletteCache[coverUrl]);
      return;
    }
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
    _paletteCache[source] = color;
    if (!mounted || token != _ambientToken) return;
    setState(() => _ambientColor = color);
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    await playQueue(context, _tracks);
  }

  /// Reproduce toda la playlist en modo aleatorio: activa el shuffle del
  /// reproductor (el auto-advance seguirá en aleatorio) y arranca la cola.
  Future<void> _playShuffled() async {
    if (_tracks.isEmpty) return;
    final player = context.read<PlayerService>();
    if (!player.shuffle.value) player.toggleShuffle();
    await playQueue(context, _tracks);
  }

  Future<void> _removeTrack(Track track) async {
    await context.read<AppDatabase>().removeFromPlaylist(
      widget.playlist.id,
      track.id,
    );
  }

  /// Menú contextual (clic derecho) sobre una canción del playlist.
  Future<void> _showTrackMenu(Track track, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      // Anclaje correcto: la recta es de tamaño cero en la posición del
      // cursor (right/bottom son offsets desde los bordes del overlay).
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'play',
          child: Row(
            children: [
              Icon(Icons.play_arrow_rounded),
              SizedBox(width: 10),
              Text('Reproducir'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.remove_circle_outline),
              SizedBox(width: 10),
              Text('Quitar de la playlist'),
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'play':
        await playTrack(context, track);
      case 'remove':
        await _removeTrack(track);
    }
  }

  // ------------------------------------------------------------ edición

  /// Modal para editar la playlist (nombre, descripción y portada).
  Future<void> _editPlaylist() async {
    final db = context.read<AppDatabase>();
    final playlist = _playlist ?? widget.playlist;
    final result =
        await showDialog<
          ({
            String name,
            String? description,
            String? coverToCopy,
            String? coverUrl,
            bool removeCover,
          })
        >(
          context: context,
          builder: (_) =>
              _EditPlaylistDialog(playlist: playlist, tracks: _tracks),
        );
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = result.name.trim();
      if (name.isNotEmpty && name != playlist.name) {
        await db.renamePlaylist(playlist.id, name);
      }
      await db.setPlaylistDescription(playlist.id, result.description);

      final currentCover = (await db.getPlaylist(playlist.id))?.coverUrl;
      String? newCover = currentCover;
      if (result.removeCover) {
        newCover = null;
      } else if (result.coverToCopy != null) {
        newCover = await copyPlaylistCoverToAppDir(
          playlist.id,
          result.coverToCopy!,
        );
      } else if (result.coverUrl != null) {
        newCover = result.coverUrl;
      }
      final coverChanged =
          result.removeCover ||
          result.coverToCopy != null ||
          result.coverUrl != null;
      if (coverChanged && newCover != currentCover) {
        await db.setPlaylistCover(playlist.id, newCover);
        // Limpiar la portada local anterior (no deja huérfanos).
        if (currentCover != null &&
            CoverImage.isLocalPath(currentCover) &&
            newCover != currentCover) {
          final old = File(currentCover);
          if (await old.exists()) await old.delete();
        }
      }

      if (!mounted) return;
      showScrupSnackBar(messenger, 'Playlist actualizada');
      final updated = await db.getPlaylist(playlist.id);
      if (mounted && updated != null) {
        widget.onUpdated?.call(updated);
      }
    } catch (_) {
      if (!mounted) return;
      showScrupSnackBar(messenger, 'No se pudo guardar los cambios');
    }
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    if (m < 1) return 'menos de 1 min';
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? '$h h' : '$h h $rem min';
  }

  String get _countAndDuration {
    final count = _tracks.length;
    final total = _tracks.fold(
      Duration.zero,
      (acc, t) => acc + (t.duration ?? Duration.zero),
    );
    return '$count ${count == 1 ? 'canción' : 'canciones'}'
        ' · ${_fmtDuration(total)}';
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
  /// `onPrimary` con contraste legible), en lugar del acento de la canción.
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
    // Mientras se ve la playlist, botones y elementos usan el color de SU
    // portada (no el acento de la canción en reproducción).
    final theme = playlistColor != null
        ? _themeWithPlaylistColor(baseTheme, playlistColor)
        : baseTheme;
    final playlist = _playlist ?? widget.playlist;
    final count = _tracks.length;
    final ambient = _ambientColor;
    final base = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.55,
    );

    return Theme(
      data: theme,
      child: Container(
        // Margen flotante + sombra exterior (fuera del clip)
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
            // Cristal: difumina lo que pase por detrás
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                // Translúcido + tinte del color de la portada
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [ambient?.withValues(alpha: 0.20) ?? base, base],
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hero de presentación
                    Container(
                      decoration: BoxDecoration(
                        // Ambiente: degradado del color de la portada que se
                        // desvanece hacia abajo.
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            ambient?.withValues(alpha: 0.30) ??
                                Colors.transparent,
                            Colors.transparent,
                          ],
                          stops: const [0.0, 1.0],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 24, 20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Portada grande (hover muestra acciones de
                            // edición)
                            _heroCover(theme, playlist.coverUrl),
                            const SizedBox(width: 24),
                            // Título + descripción + acciones
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    playlist.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.displaySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          height: 1.05,
                                        ),
                                  ),
                                  if (playlist.description != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      playlist.description!,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.9),
                                          ),
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  // Reproducir + shuffle + conteo/duración
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: count == 0 ? null : _playAll,
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        label: const Text('Reproducir'),
                                      ),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: context
                                            .read<PlayerService>()
                                            .shuffle,
                                        builder: (context, shuffleOn, _) {
                                          return IconButton(
                                            icon: Icon(
                                              Icons.shuffle,
                                              color: shuffleOn
                                                  ? theme.colorScheme.primary
                                                  : theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                            ),
                                            tooltip: 'Reproducir en aleatorio',
                                            onPressed: count == 0
                                                ? null
                                                : _playShuffled,
                                          );
                                        },
                                      ),
                                      Text(
                                        _countAndDuration,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
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
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
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
                              // El player flotante cubre la parte inferior.
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                8,
                                12,
                                kPlayerOverlayInset,
                              ),
                              itemCount: _tracks.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 4),
                              itemBuilder: (context, i) {
                                final track = _tracks[i];
                                return GestureDetector(
                                  onSecondaryTapUp: (details) => _showTrackMenu(
                                    track,
                                    details.globalPosition,
                                  ),
                                  child: TrackTile(
                                    track: track,
                                    onPlay: () => playTrack(context, track),
                                  ),
                                );
                              },
                            ),
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

  /// Portada grande del hero con overlay de edición al hacer hover (y un
  /// tap en la portada también abre el modal de edición).
  Widget _heroCover(ThemeData theme, String? coverUrl) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _coverHovered = true),
      onExit: (_) => setState(() => _coverHovered = false),
      child: GestureDetector(
        onTap: _editPlaylist,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              SizedBox(
                width: 160,
                height: 160,
                child: _coverArt(theme, coverUrl),
              ),
              // Overlay de edición (solo en hover)
              if (_coverHovered)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_rounded, size: 26),
                            color: Colors.white,
                            tooltip: 'Editar playlist',
                            onPressed: _editPlaylist,
                          ),
                          Text(
                            'Editar',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal para editar una playlist: nombre, descripción y portada (desde
/// archivo, desde una canción de la playlist, o quitarla).
class _EditPlaylistDialog extends StatefulWidget {
  final Playlist playlist;
  final List<Track> tracks;

  const _EditPlaylistDialog({required this.playlist, required this.tracks});

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  String? _imagePath;
  String? _trackCoverUrl;
  bool _removeCover = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.playlist.name);
    _descController = TextEditingController(
      text: widget.playlist.description ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    const images = XTypeGroup(
      label: 'Imágenes',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;
    setState(() {
      _imagePath = file.path;
      _trackCoverUrl = null;
      _removeCover = false;
    });
  }

  Future<void> _pickTrackCover() async {
    if (widget.tracks.isEmpty) return;
    final url = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Portada desde una canción',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final track in widget.tracks.take(12))
              ListTile(
                dense: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CoverImage(
                      source: track.thumbnailUrl,
                      fallback: _thumbnailFallback(ctx),
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
                onTap: () => Navigator.pop(ctx, track.thumbnailUrl),
              ),
          ],
        ),
      ),
    );
    if (url == null || !mounted) return;
    setState(() {
      _trackCoverUrl = url;
      _imagePath = null;
      _removeCover = false;
    });
  }

  Widget _thumbnailFallback(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.music_note,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// Fuente que se mostrará en la vista previa (lo que quedará como portada).
  String? get _previewSource {
    if (_imagePath != null) return _imagePath;
    if (_trackCoverUrl != null) return _trackCoverUrl;
    if (_removeCover) return null;
    return widget.playlist.coverUrl;
  }

  String get _previewLabel {
    if (_imagePath != null) return p.basename(_imagePath!);
    if (_trackCoverUrl != null) return 'Portada de una canción';
    if (_removeCover) return 'Sin portada';
    return widget.playlist.coverUrl != null ? 'Portada actual' : 'Sin portada';
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final desc = _descController.text.trim();
    Navigator.pop(context, (
      name: name,
      description: desc.isEmpty ? null : desc,
      coverToCopy: _imagePath,
      coverUrl: _trackCoverUrl,
      removeCover: _removeCover,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Editar playlist'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nombre'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              maxLines: 3,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Descripción'),
            ),
            const SizedBox(height: 4),
            // Portada: preview + acciones
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: CoverImage(
                      source: _previewSource,
                      cacheWidth: 120,
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
                          size: 20,
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _previewLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.image_outlined, size: 20),
                  tooltip: 'Elegir imagen',
                  onPressed: _pickImage,
                ),
                IconButton(
                  icon: const Icon(Icons.library_music_outlined, size: 20),
                  tooltip: 'Portada de una canción',
                  onPressed: _pickTrackCover,
                ),
                if (_previewSource != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Quitar portada',
                    onPressed: () => setState(() {
                      _imagePath = null;
                      _trackCoverUrl = null;
                      _removeCover = true;
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Guardar')),
      ],
    );
  }
}
