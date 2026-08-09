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
import '../../l10n/generated/app_localizations.dart';
import '../../services/playlist_cover_store.dart';
import '../../services/player_service.dart';
import '../playback.dart';
import '../theme_controller.dart';
import '../widgets/context_menu_item.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
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
    final l10n = AppLocalizations.of(context);
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
      items: [
        ContextMenuItem(
          value: 'play',
          icon: Icons.play_arrow_rounded,
          label: l10n.play,
        ),
        ContextMenuItem(
          value: 'remove',
          icon: Icons.remove_circle_outline,
          label: l10n.removeFromPlaylist,
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
    final l10n = AppLocalizations.of(context);
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
      showScrupSnackBar(messenger, l10n.playlistUpdated);
      final updated = await db.getPlaylist(playlist.id);
      if (mounted && updated != null) {
        widget.onUpdated?.call(updated);
      }
    } catch (_) {
      if (!mounted) return;
      showScrupSnackBar(messenger, l10n.cantSaveChanges);
    }
  }

  String _fmtDuration(Duration d, AppLocalizations l10n) {
    final m = d.inMinutes;
    if (m < 1) return l10n.lessThanOneMinute;
    if (m < 60) return l10n.durationMinutes(m);
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? l10n.durationHours(h) : l10n.durationHoursMinutes(h, rem);
  }

  String get _countAndDuration {
    final l10n = AppLocalizations.of(context);
    final count = _tracks.length;
    final total = _tracks.fold(
      Duration.zero,
      (acc, t) => acc + (t.duration ?? Duration.zero),
    );
    return l10n.playlistMeta(l10n.songCount(count), _fmtDuration(total, l10n));
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
    final l10n = AppLocalizations.of(context);
    final playlistColor = _ambientColor;
    // Mientras se ve la playlist, botones y elementos usan el color de SU
    // portada (no el acento de la canción en reproducción).
    final theme = playlistColor != null
        ? _themeWithPlaylistColor(baseTheme, playlistColor)
        : baseTheme;
    final playlist = _playlist ?? widget.playlist;
    final count = _tracks.length;

    return Theme(
      data: theme,
      child: Container(
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
          child: BackdropFilter(
            // Cristal: difumina lo que pase por detrás
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                // Cristal: la MISMA base oscura translúcida que el sidebar
                // (mismos dos tonos y alphas), pero en el detalle se le añade
                // un matiz sutil del color de la portada de la playlist
                // (solo aquí; el sidebar se queda neutro).
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    if (playlistColor != null)
                      // Tinte SOLO del tono: se mezclan los colores opacos
                      // (sin alpha) y luego se aplica el mismo alpha 0.55 del
                      // sidebar, para que la translucidez coincida exactamente
                      // (Color.lerp también interpolaría el canal alfa y el
                      // detalle quedaría más opaco que el sidebar).
                      Color.lerp(
                        theme.colorScheme.surfaceContainerHighest,
                        playlistColor,
                        0.30,
                      )!.withValues(alpha: 0.55)
                    else
                      theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
                    theme.colorScheme.surfaceContainer.withValues(alpha: 0.55),
                  ],
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hero de presentación (cristal limpio, sin ambiente de
                    // color de la portada)
                    Padding(
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
                                  style: theme.textTheme.displaySmall?.copyWith(
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
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.9),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 16),
                                // Reproducir + shuffle + conteo/duración
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: count == 0 ? null : _playAll,
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: Text(l10n.play),
                                    ),
                                    FilledButton.icon(
                                      onPressed: count == 0
                                          ? null
                                          : _playShuffled,
                                      // Mismo diseño que el botón de play,
                                      // pero con fondo blanco y el texto/icono
                                      // en el color acento de la playlist.
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor:
                                            theme.colorScheme.primary,
                                      ),
                                      // Label corto: solo "Aleatorio"; el
                                      // texto largo anterior agrandaba el
                                      // botón respecto al de play.
                                      icon: const Icon(Icons.shuffle),
                                      label: Text(l10n.shuffle),
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
                                    l10n.emptyPlaylist,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.emptyPlaylistHint,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              // El contenedor ya termina por encima del
                              // player (margen inferior), así que aquí solo
                              // hace falta un respiro pequeño.
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
                            tooltip: AppLocalizations.of(context).editPlaylist,
                            onPressed: _editPlaylist,
                          ),
                          Text(
                            AppLocalizations.of(context).edit,
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
    final images = XTypeGroup(
      label: AppLocalizations.of(context).images,
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
                AppLocalizations.of(ctx).coverFromTrack,
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
    final l10n = AppLocalizations.of(context);
    if (_imagePath != null) return p.basename(_imagePath!);
    if (_trackCoverUrl != null) return l10n.coverFromTrackLabel;
    if (_removeCover) return l10n.noCover;
    return widget.playlist.coverUrl != null ? l10n.currentCover : l10n.noCover;
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
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.editPlaylist),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.playlistName),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              maxLines: 3,
              maxLength: 300,
              decoration: InputDecoration(labelText: l10n.description),
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
                  tooltip: l10n.chooseImage,
                  onPressed: _pickImage,
                ),
                IconButton(
                  icon: const Icon(Icons.library_music_outlined, size: 20),
                  tooltip: l10n.coverFromTrackLabel,
                  onPressed: _pickTrackCover,
                ),
                if (_previewSource != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: l10n.removeCover,
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
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.save)),
      ],
    );
  }
}
