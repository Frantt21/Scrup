import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/update_service.dart';
import 'scrup_toasts.dart';

/// Aviso de nueva versión. El botón principal descarga e instala el archivo de
/// la plataforma (APK en Android, instalador en Windows); en Linux no hay
/// self-install, así que abre la página del release en el navegador.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => UpdateDialog(info: info),
  );
}

class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;

  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _busy = false;
  int _received = 0;
  int _total = 0;
  bool _error = false;

  Future<void> _primary() async {
    final l10n = AppLocalizations.of(context);
    final service = context.read<UpdateService>();
    final info = widget.info;
    final asset = info.asset;

    // Sin asset (Linux): abrir el release en el navegador.
    if (asset == null) {
      final ok = await service.openUrl(info.releaseUrl);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = true);
      }
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _received = 0;
      _total = asset.size;
    });
    try {
      final file = await service.downloadAsset(
        info,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      await service.install(file);
      if (!mounted) return;
      showScrupToast(l10n.updateInstalling, kind: ScrupToastKind.info);
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
      });
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 'B';
    for (final u in units) {
      value /= 1024;
      unit = u;
      if (value < 1024) break;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} $unit';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final info = widget.info;
    final isReleaseLink = info.asset == null;
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_alt_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(l10n.updateAvailableTitle)),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: theme.colorScheme.primary.withValues(alpha: 0.18),
                  ),
                  child: Text(
                    'v${info.version}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                    ),
                    child: Text(
                      info.notes,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                '${l10n.updateDownloading}  '
                '${_fmtBytes(_received)}'
                '${_total > 0 ? ' / ${_fmtBytes(_total)}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_error) ...[
              const SizedBox(height: 12),
              Text(
                l10n.updateError,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.updateLater),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _primary,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  isReleaseLink
                      ? Icons.open_in_new_rounded
                      : Icons.download_rounded,
                  size: 18,
                ),
          label: Text(
            isReleaseLink ? l10n.updateOpenRelease : l10n.updateDownloadAndInstall,
          ),
        ),
      ],
    );
  }
}
