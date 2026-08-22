import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/deezer_service.dart';
import '../../services/playlist_cover_store.dart';
import 'cover_image.dart';
import 'scrup_toasts.dart';

/// Diálogo para editar manualmente los metadatos de una pista (título,
/// artista, álbum y portada). Devuelve el [Track] actualizado al pulsar
/// Guardar, o `null` si se cancela. Mismo estilo glass que el resto de
/// diálogos de la app. Compartido por el player bar (clic derecho) y el
/// menú contextual de pistas en el detalle de playlist.
class EditMetadataDialog extends StatefulWidget {
  final Track track;

  const EditMetadataDialog({super.key, required this.track});

  @override
  State<EditMetadataDialog> createState() => _EditMetadataDialogState();
}

class _EditMetadataDialogState extends State<EditMetadataDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _album;
  late final TextEditingController _cover;

  /// `true` mientras se busca la metadata en Deezer (spinner en el botón).
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.track.title);
    _artist = TextEditingController(text: widget.track.artist);
    _album = TextEditingController(text: widget.track.album ?? '');
    _cover = TextEditingController(text: widget.track.thumbnailUrl ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _cover.dispose();
    super.dispose();
  }

  /// Construye el track actualizado a partir de los campos (el id y la
  /// duración se conservan: la fuente de audio no cambia).
  Track _buildTrack() {
    final t = widget.track;
    final title = _title.text.trim();
    final artist = _artist.text.trim();
    final album = _album.text.trim();
    final cover = _cover.text.trim();
    return t.copyWith(
      title: title.isEmpty ? t.title : title,
      artist: artist,
      album: album.isEmpty ? null : album,
      thumbnailUrl: cover.isEmpty ? null : cover,
    );
  }

  /// Busca la metadata en Deezer con el título/artista ESCRITOS en los
  /// campos (no la metadata incrustada del video): así el usuario puede
  /// corregir el artista/título y buscar de nuevo. `searchManual` evita la
  /// caché por videoId (si el enriquecimiento automático ya cacheó un
  /// resultado o un `null` para ese video, la búsqueda manual debe
  /// consultar la API igualmente). Si no hay coincidencia fiable, deja los
  /// campos intactos y avisa.
  Future<void> _searchDeezer() async {
    if (_searching) return;
    final l10n = AppLocalizations.of(context);
    final title = _title.text.trim();
    final artist = _artist.text.trim();
    if (title.isEmpty && artist.isEmpty) return;
    setState(() => _searching = true);
    try {
      final enriched = await context
          .read<DeezerService>()
          .searchManual(title, artist);
      if (!mounted) return;
      if (enriched == null) {
        showScrupToast(l10n.metadataNotFound, kind: ScrupToastKind.error);
        return;
      }
      setState(() {
        _title.text = enriched.title;
        _artist.text = enriched.artist;
        _album.text = enriched.album ?? '';
        _cover.text = enriched.thumbnailUrl ?? '';
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Abre el selector de archivos para elegir una imagen local como portada
  /// de la pista. La imagen se COPIA al directorio de portadas de la app
  /// (sobrevive aunque el archivo original se mueva/borre) y la ruta local
  /// resultante rellena el campo de portada.
  Future<void> _pickLocalCover() async {
    final l10n = AppLocalizations.of(context);
    final images = XTypeGroup(
      label: l10n.images,
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [images]);
    if (file == null || !mounted) return;
    try {
      final dest = await copyTrackCoverToAppDir(
        widget.track.id,
        file.path,
      );
      if (!mounted) return;
      setState(() => _cover.text = dest);
    } catch (_) {
      if (!mounted) return;
      showScrupToast(
        l10n.metadataCoverError,
        kind: ScrupToastKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          // Fondo sólido (sin borde ni gradiente translúcido).
          color: theme.colorScheme.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.editMetadata,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.metadataSearchHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.close,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(
                    l10n.metadataTitle,
                    _title,
                    Icons.music_note,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l10n.metadataArtist,
                    _artist,
                    Icons.person,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l10n.metadataAlbum,
                    _album,
                    Icons.album,
                  ),
                  const SizedBox(height: 16),
                  // Portada: miniatura en vivo + campo de URL + botón para
                  // elegir una imagen local (se copia al dir de la app).
                  _field(
                    l10n.metadataCoverUrl,
                    _cover,
                    Icons.link,
                    trailing: IconButton(
                      icon: const Icon(Icons.photo_library, size: 20),
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.chooseImage,
                      onPressed: _pickLocalCover,
                    ),
                    onChanged: (_) => setState(() {}),
                    preview: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: CoverImage(
                          source: _cover.text.trim().isEmpty
                              ? null
                              : _cover.text.trim(),
                          fit: BoxFit.cover,
                          fallback: Container(
                            color: theme.colorScheme.surfaceContainerHigh,
                            child: Icon(
                              Icons.image,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Buscar en Deezer (autocompleta los campos) junto a
                  // Cancelar/Guardar.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: _searching ? null : _searchDeezer,
                        icon: _searching
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome, size: 16),
                        label: Text(l10n.metadataSearchDeezer),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(l10n.cancel),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(context, _buildTrack()),
                            child: Text(l10n.save),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Campo con su label como título ENCIMA (fuera del borde del input) y el
  /// input debajo. [trailing] permite un botón extra dentro del input (p. ej.
  /// elegir imagen) y [preview] una miniatura al lado (p. ej. la portada).
  Widget _field(
    String label,
    TextEditingController controller,
    IconData icon, {
    Widget? trailing,
    ValueChanged<String>? onChanged,
    Widget? preview,
  }) {
    final theme = Theme.of(context);
    final input = TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: label,
        prefixIcon: Icon(icon, size: 18),
        suffixIcon: trailing,
        filled: true,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      style: theme.textTheme.bodyMedium,
      onChanged: onChanged,
    );
    final field = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        input,
      ],
    );
    if (preview == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: field),
        const SizedBox(width: 12),
        preview,
      ],
    );
  }
}
