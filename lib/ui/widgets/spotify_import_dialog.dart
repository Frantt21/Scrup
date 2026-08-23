import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/spotify_import_service.dart';
import '../../services/ytdlp_service.dart';
import '../../services/ytmusic_service.dart';

/// Abre el diálogo de migración de una playlist de Spotify a Scrup.
/// Devuelve el nombre elegido y las pistas emparejadas en YouTube, o null
/// si el usuario cancela.
Future<({String name, List<Track> tracks})?> showSpotifyImportDialog(
  BuildContext context,
) {
  return showDialog<({String name, List<Track> tracks})>(
    context: context,
    builder: (_) => const SpotifyImportDialog(),
  );
}

enum _Phase { url, fetching, matching, done }

enum _RowStatus { searching, matched, unmatched }

class _RowState {
  _RowState({this.status = _RowStatus.searching, this.track});
  final _RowStatus status;
  final Track? track;
}

class SpotifyImportDialog extends StatefulWidget {
  const SpotifyImportDialog({super.key});

  @override
  State<SpotifyImportDialog> createState() => _SpotifyImportDialogState();
}

class _SpotifyImportDialogState extends State<SpotifyImportDialog> {
  final _urlCtrl = TextEditingController();
  var _phase = _Phase.url;
  String? _error;
  SpotifyPlaylist? _playlist;
  List<_RowState> _rows = const [];
  int _matched = 0;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_urlCtrl.text.trim().isEmpty || _phase == _Phase.fetching) return;
    final l10n = AppLocalizations.of(context);
    final service = SpotifyImportService();
    setState(() {
      _phase = _Phase.fetching;
      _error = null;
    });
    SpotifyPlaylist playlist;
    try {
      playlist = await service.fetchPlaylist(_urlCtrl.text);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.url;
        _error = l10n.spotifyFetchError;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _playlist = playlist;
      _rows = [
        for (var i = 0; i < playlist.tracks.length; i++) _RowState(),
      ];
      _matched = 0;
      _phase = _Phase.matching;
    });
    await service.importToYoutube(
      playlist: playlist,
      ytDlp: context.read<YtDlpService>(),
      ytMusic: YtMusicService(),
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _rows[r.index] = _RowState(
            status: r.hasMatch ? _RowStatus.matched : _RowStatus.unmatched,
            track: r.match,
          );
          if (r.hasMatch) _matched++;
        });
      },
    );
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
  }

  void _confirm() {
    final playlist = _playlist;
    if (playlist == null || _matched == 0) return;
    Navigator.pop(context, (
      name: playlist.name,
      tracks: [
        for (final r in _rows)
          if (r.status == _RowStatus.matched && r.track != null) r.track!,
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final total = _playlist?.tracks.length ?? 0;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.sync_alt),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.importSpotify)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: switch (_phase) {
          _Phase.url || _Phase.fetching => _buildUrlInput(theme, l10n),
          _Phase.matching || _Phase.done =>
            _buildProgress(theme, l10n, total),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        if (_phase == _Phase.url || _phase == _Phase.fetching)
          FilledButton(
            onPressed:
                _urlCtrl.text.trim().isEmpty ? null : () => unawaited(_start()),
            child: Text(l10n.importAction),
          )
        else
          FilledButton(
            // Al menos una coincidencia para crear la playlist.
            onPressed: _matched > 0 ? _confirm : null,
            child: Text(_phase == _Phase.done ? l10n.done : l10n.close),
          ),
      ],
    );
  }

  Widget _buildUrlInput(ThemeData theme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _urlCtrl,
          autofocus: true,
          enabled: _phase == _Phase.url,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => unawaited(_start()),
          decoration: InputDecoration(hintText: l10n.spotifyUrlHint),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12.5),
          ),
        ],
        if (_phase == _Phase.fetching) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  Widget _buildProgress(ThemeData theme, AppLocalizations l10n, int total) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _playlist!.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          '$_matched / $total',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 300,
          width: 380,
          child: ListView.builder(
            itemCount: _rows.length,
            itemBuilder: (context, i) => _buildRow(theme, l10n, i),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ThemeData theme, AppLocalizations l10n, int index) {
    final row = _rows[index];
    final track = _playlist!.tracks[index];

    final Widget trailing = switch (row.status) {
      _RowStatus.searching => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      _RowStatus.matched => Icon(
        Icons.check_circle_outline,
        size: 18,
        color: Colors.green.shade400,
      ),
      _RowStatus.unmatched => Tooltip(
        message: l10n.spotifyNoMatch,
        child: Icon(
          Icons.remove_circle_outline,
          size: 18,
          color: theme.colorScheme.outline,
        ),
      ),
    };

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 20,
      leading: Text('${index + 1}'),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        track.artists,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: trailing,
    );
  }
}
