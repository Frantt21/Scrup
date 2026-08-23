import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/spotify_import_service.dart';
import '../../services/ytdlp_service.dart';
import '../../services/ytmusic_service.dart';

/// Abre el diálogo de migración de playlists a Scrup. Detecta la fuente por
/// el enlace: Spotify (embed público, primeras ~100) o YouTube/YouTube Music
/// (InnerTube browse, sin límite práctico). Devuelve el nombre elegido y las
/// pistas emparejadas en YouTube, o null si el usuario cancela.
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
  _RowState({
    required this.label,
    required this.sub,
    this.status = _RowStatus.searching,
    this.track,
  });
  final String label;
  final String sub;
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
  String? _playlistName;
  List<_RowState> _rows = const [];
  int _matched = 0;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final input = _urlCtrl.text.trim();
    if (input.isEmpty || _phase == _Phase.fetching) return;
    if (SpotifyImportService.extractPlaylistId(input) != null) {
      await _startSpotify(input);
    } else if (YtMusicService.extractYoutubePlaylistId(input) != null) {
      await _startYoutube(input);
    } else {
      setState(() => _error = AppLocalizations.of(context).spotifyUrlHint);
    }
  }

  /// YouTube / YT Music: los videoIds vienen exactos del browse, no hay
  /// búsqueda por pista → resultado inmediato.
  Future<void> _startYoutube(String input) async {
    setState(() {
      _phase = _Phase.fetching;
      _error = null;
    });
    YtmPlaylist playlist;
    try {
      playlist = await YtMusicService().fetchPlaylist(input);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.url;
        _error = AppLocalizations.of(context).spotifyFetchError;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _playlistName = playlist.name;
      _rows = [
        for (final t in playlist.tracks)
          _RowState(
            label: t.title,
            sub: t.artist,
            status: _RowStatus.matched,
            track: t,
          ),
      ];
      _matched = playlist.tracks.length;
      _phase = _Phase.done;
    });
  }

  /// Spotify: leer embed → emparejar cada pista contra YouTube en vivo.
  Future<void> _startSpotify(String input) async {
    final l10n = AppLocalizations.of(context);
    final service = SpotifyImportService();
    setState(() {
      _phase = _Phase.fetching;
      _error = null;
    });
    SpotifyPlaylist playlist;
    try {
      playlist = await service.fetchPlaylist(input);
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
      _playlistName = playlist.name;
      _rows = [
        for (final t in playlist.tracks)
          _RowState(label: t.title, sub: t.artists),
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
            label: r.requested.title,
            sub: r.requested.artists,
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
    if (_playlistName == null || _matched == 0) return;
    Navigator.pop(context, (
      name: _playlistName!,
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

    // Mismo shell glass que el resto de diálogos de la app (crear/editar
    // playlist, metadatos): Container sólido radio 18 + sombra profunda,
    // cabecera con X y cuerpo en padding 24.
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
                      l10n.importSpotify,
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
              child: switch (_phase) {
                _Phase.url || _Phase.fetching => _buildUrlInput(theme, l10n),
                _Phase.matching || _Phase.done =>
                  _buildProgress(theme, l10n),
              },
            ),
          ],
        ),
      ),
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
          decoration: InputDecoration(
            hintText: l10n.spotifyUrlHint,
            prefixIcon: const Icon(Icons.link_rounded, size: 18),
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
          const LinearProgressIndicator(minHeight: 3),
        ],
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
              onPressed: _urlCtrl.text.trim().isEmpty
                  ? null
                  : () => unawaited(_start()),
              child: Text(l10n.importAction),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProgress(ThemeData theme, AppLocalizations l10n) {
    final total = _rows.length;
    // El embed público de Spotify trunca ~100 pistas y no expone el total:
    // si llegamos justo al límite asumimos recorte y avisamos.
    final truncated = total >= 100;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _playlistName ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          '$_matched / $total',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (truncated) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_rounded, size: 14, color: Colors.amber.shade600),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.spotifyTruncated(total),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.amber.shade700,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 300,
          width: double.infinity,
          child: ListView.builder(
            itemCount: _rows.length,
            itemBuilder: (context, i) => _buildRow(theme, l10n, i),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            const SizedBox(width: 8),
            FilledButton(
              // Al menos una coincidencia para crear la playlist.
              onPressed: _matched > 0 && _phase == _Phase.done
                  ? _confirm
                  : null,
              child: Text(_phase == _Phase.done ? l10n.done : l10n.close),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRow(ThemeData theme, AppLocalizations l10n, int index) {
    final row = _rows[index];

    final Widget trailing = switch (row.status) {
      _RowStatus.searching => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      _RowStatus.matched => Icon(
        Icons.check_circle_rounded,
        size: 18,
        color: Colors.green.shade400,
      ),
      _RowStatus.unmatched => Tooltip(
        message: l10n.spotifyNoMatch,
        child: Icon(
          Icons.remove_circle_rounded,
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
      title: Text(row.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        row.sub,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: trailing,
    );
  }
}
