import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/generated/app_localizations.dart';

/// Dialog for creating a new playlist (name, description, cover).
/// Compartido por desktop (sidebar) y mobile (librería).
class CreatePlaylistDialog extends StatefulWidget {
  const CreatePlaylistDialog({super.key});

  @override
  State<CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<CreatePlaylistDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  String? _imagePath;

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
    setState(() => _imagePath = file.path);
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (
      name: name,
      description: _descController.text.trim(),
      imagePath: _imagePath,
    ));
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
          color: theme.colorScheme.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.newPlaylist,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
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
                      l10n.playlistName,
                      _nameController,
                      Icons.queue_music_rounded,
                      hint: l10n.playlistNameHint,
                      submit: true,
                    ),
                    const SizedBox(height: 16),
                    _field(
                      l10n.descriptionOptional,
                      _descController,
                      Icons.notes_rounded,
                      hint: l10n.descriptionHint,
                      maxLines: 3,
                      maxLength: 300,
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: _imagePath != null
                                ? Image.file(
                                    File(_imagePath!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        _placeholder(theme),
                                  )
                                : _placeholder(theme),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _imagePath == null
                                ? l10n.noCover
                                : p.basename(_imagePath!),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _imagePath == null
                                ? Icons.image_rounded
                                : Icons.swap_horiz_rounded,
                            size: 20,
                          ),
                          visualDensity: VisualDensity.compact,
                          tooltip: _imagePath == null
                              ? l10n.chooseImage
                              : l10n.changeImage,
                          onPressed: _pickImage,
                        ),
                        if (_imagePath != null)
                          IconButton(
                            icon: const Icon(Icons.delete_rounded, size: 20),
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.removeImage,
                            onPressed: () => setState(() => _imagePath = null),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(l10n.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _submit,
                          child: Text(l10n.create),
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
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    IconData icon, {
    int maxLines = 1,
    int? maxLength,
    bool submit = false,
    String? hint,
  }) {
    final theme = Theme.of(context);
    return Column(
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
        TextField(
          controller: controller,
          autofocus: controller == _nameController,
          maxLines: maxLines,
          maxLength: maxLength,
          decoration: InputDecoration(
            hintText: hint ?? label,
            prefixIcon: maxLines == 1 ? Icon(icon, size: 18) : null,
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
            counterText: '',
          ),
          style: theme.textTheme.bodyMedium,
          onSubmitted: submit ? (_) => _submit() : null,
        ),
      ],
    );
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
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
        Icons.queue_music_rounded,
        size: 20,
        color: theme.colorScheme.primary.withValues(alpha: 0.5),
      ),
    );
  }
}