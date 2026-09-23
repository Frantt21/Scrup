import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme_controller.dart';
import '../widgets/artist_avatar.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
import '../widgets/screen_header.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/search_service.dart';

/// Recap screen: listening stats (all time / last 30 days / last 7 days) —
/// total listening time, top tracks, top artists and top playlists, all from
/// the ListenSessions chunks the player persists while audio actually plays.
class RecapView extends StatefulWidget {
  final VoidCallback? onBack;

  const RecapView({super.key, this.onBack});

  @override
  State<RecapView> createState() => _RecapViewState();
}

enum _RecapRange { all, month, week }

/// Lado común de los tiles (artwork/artista/playlist) del recap.
const double _recapTileSide = 52;

/// Radio de esquina compartido con los artworks de la app.
const double _recapTileRadius = 8;

class _RecapViewState extends State<RecapView> {
  _RecapRange _range = _RecapRange.all;
  bool _loading = true;
  int _totalSeconds = 0;
  List<(Track, int)> _topTracks = const [];
  List<(String, int)> _topArtists = const [];
  Map<String, String?> _artistAvatars = const {};
  Map<String, String> _artistChannels = const {};
  List<RecapPlaylistEntry> _topPlaylists = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? get _since {
    switch (_range) {
      case _RecapRange.all:
        return null;
      case _RecapRange.month:
        return DateTime.now().subtract(const Duration(days: 30));
      case _RecapRange.week:
        return DateTime.now().subtract(const Duration(days: 7));
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = context.read<AppDatabase>();
    final since = _since;
    final total = await db.totalListenSeconds(since: since);
    final tracks = await db.topListenedTracks(since: since, limit: 10);
    final artists = await db.topListenedArtists(since: since, limit: 10);
    final playlists = await db.topListenedPlaylists(since: since, limit: 10);
    final avatars = await _avatarsForTracks(tracks);
    if (!mounted) return;
    setState(() {
      _totalSeconds = total;
      _topTracks = tracks;
      _topArtists = artists;
      _topPlaylists = playlists;
      _artistAvatars = avatars.$1;
      _artistChannels = avatars.$2;
      _loading = false;
    });
    // Faces missing from cache go to InnerTube in background; each one
    // repaints its row when it resolves.
    unawaited(_resolveMissingAvatars());
  }

  /// Disk-first avatar map for the top tracks: per-track channel from the
  /// TrackInfoCache (already resolved for the now-playing panel), then the
  /// shared avatar cache search/home populate. One entry per artist name.
  Future<(Map<String, String?>, Map<String, String>)> _avatarsForTracks(
    List<(Track, int)> tracks,
  ) async {
    // Providers are read through SearchService's read-only getters: the
    // recap must not depend on where each store is provided in the tree.
    final search = context.read<SearchService>();
    final info = search.trackInfoCache;
    final shared = search.avatarCache;
    final urls = <String, String?>{};
    final channels = <String, String>{};
    for (final (t, _) in tracks) {
      final name = t.artist.trim();
      if (name.isEmpty || urls.containsKey(name)) continue;
      var channelId = t.artistChannelId;
      final ch = await info?.readChannel(t.id);
      if (ch != null && ch.$1.isNotEmpty) channelId = ch.$1;
      if (channelId != null && channelId.isNotEmpty) {
        channels[name] = channelId;
        urls[name] = await shared?.get(channelId);
      }
    }
    return (urls, channels);
  }

  /// For top artists without a cached face: resolve the track's channel
  /// (InnerTube `next`) and fetch the channel page. Saves channel + avatar
  /// in the shared stores so search, home and the panel reuse them.
  Future<void> _resolveMissingAvatars() async {
    final search = context.read<SearchService>();
    final info = search.trackInfoCache;
    final shared = search.avatarCache;
    for (final (t, _) in _topTracks) {
      if (!mounted) return;
      final name = t.artist.trim();
      if (name.isEmpty) continue;
      if (_artistAvatars[name] != null) continue;
      var channelId = _artistChannels[name] ?? t.artistChannelId;
      if (channelId == null || channelId.isEmpty) {
        try {
          final owner = await search.fetchTrackChannel(t.id);
          if (owner == null || !mounted) continue;
          channelId = owner.$1;
          info?.writeChannel(t.id, owner.$1, owner.$2);
          // Self-heal the DB row so future rounds skip this lookup.
          await context.read<AppDatabase>().cacheTrack(
            t.copyWith(artistChannelId: owner.$1),
          );
          if (!mounted) return;
          setState(() => _artistChannels[name] = owner.$1);
        } catch (_) {
          continue;
        }
      }
      try {
        final detail = await search.fetchArtistDetail(channelId, name: name);
        final url = detail?.thumbnailUrl;
        if (url == null || url.isEmpty) continue;
        unawaited(shared?.put(channelId, url));
        if (!mounted) return;
        setState(() => _artistAvatars[name] = url);
      } catch (_) {
        // Offline / failed: placeholder stays for this round.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final bool mobile = Binaries.isMobile;
    final accent = context.watch<ThemeController>().accentColor ??
        theme.colorScheme.primary;

    final Widget body = Material(
      color: Colors.transparent,
      child: CustomScrollView(
        slivers: [
          // Header pinned transparente (igual que settings): título + back.
          if (mobile)
            SliverPersistentHeader(
              pinned: true,
              floating: false,
              delegate: ScreenHeaderDelegate(
                topInset: MediaQuery.paddingOf(context).top,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.recapTitle,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              mobile ? 16 : 20,
              mobile ? 8 : 20,
              mobile ? 16 : 20,
              12,
            ),
            sliver: SliverList.list(
              children: [
                if (!mobile)
                  Text(
                    l10n.recapTitle,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                const SizedBox(height: 16),
                _RangeSwitch(
                  selected: _range,
                  accent: accent,
                  onChanged: (r) {
                    setState(() => _range = r);
                    _load();
                  },
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_totalSeconds == 0)
                  _EmptyRecap(theme: theme)
                else ...[
                  _TotalCard(theme: theme, accent: accent, seconds: _totalSeconds),
                  const SizedBox(height: 20),
                  _TopTracksCard(
                    theme: theme,
                    accent: accent,
                    items: _topTracks,
                  ),
                  const SizedBox(height: 20),
                  _TopArtistsCard(
                    theme: theme,
                    accent: accent,
                    items: _topArtists,
                    avatars: _artistAvatars,
                  ),
                  const SizedBox(height: 20),
                  _TopPlaylistsCard(
                    theme: theme,
                    accent: accent,
                    items: _topPlaylists,
                  ),
                ],
              ],
            ),
          ),
          // Clearance del player flotante (desktop).
          SliverToBoxAdapter(child: SizedBox(height: kPlayerClearance)),
        ],
      ),
    );

    if (mobile) return body;

    // Desktop: el MISMO contenedor flotante que settings/playlist (margen,
    // sombra y superficie plano con el borde 18).
    return Container(
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
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.72,
            ),
          ),
          child: body,
        ),
      ),
    );
  }
}

// ── Rango de tiempo: pills ─────────────────────────────────────────────────

class _RangeSwitch extends StatelessWidget {
  final _RecapRange selected;
  final Color accent;
  final ValueChanged<_RecapRange> onChanged;

  const _RangeSwitch({
    required this.selected,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _RangePill(
          label: l10n.recapRangeAll,
          accent: accent,
          selected: selected == _RecapRange.all,
          onTap: () => onChanged(_RecapRange.all),
        ),
        _RangePill(
          label: l10n.recapRangeMonth,
          accent: accent,
          selected: selected == _RecapRange.month,
          onTap: () => onChanged(_RecapRange.month),
        ),
        _RangePill(
          label: l10n.recapRangeWeek,
          accent: accent,
          selected: selected == _RecapRange.week,
          onTap: () => onChanged(_RecapRange.week),
        ),
      ],
    );
  }
}

class _RangePill extends StatelessWidget {
  final String label;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  const _RangePill({
    required this.label,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

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
              ? accent
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: selected
                ? ArtworkPaletteService.prefersBlackInk(accent)
                    ? Colors.black
                    : Colors.white
                : theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}

// ── Total ───────────────────────────────────────────────────────────────────

class _TotalCard extends StatelessWidget {
  final ThemeData theme;
  final Color accent;
  final int seconds;

  const _TotalCard({
    required this.theme,
    required this.accent,
    required this.seconds,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.headphones_rounded, color: accent, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.recapTotalTime,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  h > 0
                      ? l10n.recapHoursMinutes(h, m)
                      : l10n.recapMinutes(m),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Top canciones ──────────────────────────────────────────────────────────

class _TopTracksCard extends StatelessWidget {
  final ThemeData theme;
  final Color accent;
  final List<(Track, int)> items;

  const _TopTracksCard({
    required this.theme,
    required this.accent,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.recapTopTracks,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          _TrackStatRow(
            theme: theme,
            accent: accent,
            index: i + 1,
            track: items[i].$1,
            seconds: items[i].$2,
          ),
      ],
    );
  }
}

class _TrackStatRow extends StatelessWidget {
  final ThemeData theme;
  final Color accent;
  final int index;
  final Track track;
  final int seconds;

  const _TrackStatRow({
    required this.theme,
    required this.accent,
    required this.index,
    required this.track,
    required this.seconds,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$index',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: index <= 3 ? accent : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(_recapTileRadius),
            child: SizedBox(
              width: _recapTileSide,
              height: _recapTileSide,
              child: CoverImage(
                source: track.thumbnailUrl,
                fit: BoxFit.cover,
                cacheWidth: (_recapTileSide * 2).round(),
                fallback: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.music_note_rounded,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _fmtDuration(context, seconds),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDuration(BuildContext context, int seconds) {
    final l10n = AppLocalizations.of(context);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return l10n.recapHoursMinutes(h, m);
    return l10n.recapMinutes(m);
  }
}

// ── Top artistas ───────────────────────────────────────────────────────────

class _TopArtistsCard extends StatelessWidget {
  final ThemeData theme;
  final Color accent;
  final List<(String, int)> items;

  /// Artist name → avatar URL (disk/in-memory; may be null while loading).
  final Map<String, String?> avatars;

  const _TopArtistsCard({
    required this.theme,
    required this.accent,
    required this.items,
    required this.avatars,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.recapTopArtists,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: i < 3
                          ? accent
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Mismo tamaño/radio que los artworks: caras cuadradas
                // redondeadas alineadas con las portadas.
                ArtistAvatarImage(
                  url: avatars[items[i].$1],
                  side: _recapTileSide,
                  radius: _recapTileRadius,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    items[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _fmt(context, items[i].$2),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _fmt(BuildContext context, int seconds) {
    final l10n = AppLocalizations.of(context);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return l10n.recapHoursMinutes(h, m);
    return l10n.recapMinutes(m);
  }
}

// ── Top playlists ──────────────────────────────────────────────────────────

class _TopPlaylistsCard extends StatelessWidget {
  final ThemeData theme;
  final Color accent;
  final List<RecapPlaylistEntry> items;

  const _TopPlaylistsCard({
    required this.theme,
    required this.accent,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.recapTopPlaylists,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: i < 3
                          ? accent
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(_recapTileRadius),
                  child: SizedBox(
                    width: _recapTileSide,
                    height: _recapTileSide,
                    child: CoverImage(
                      source: items[i].coverUrl,
                      fit: BoxFit.cover,
                      cacheWidth: (_recapTileSide * 2).round(),
                      fallback: ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.queue_music_rounded,
                          size: 22,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    items[i].name.isEmpty
                        ? l10n.recapDeletedPlaylist
                        : items[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontStyle: items[i].name.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: items[i].name.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
                Text(
                  _fmt(context, items[i].seconds),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _fmt(BuildContext context, int seconds) {
    final l10n = AppLocalizations.of(context);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return l10n.recapHoursMinutes(h, m);
    return l10n.recapMinutes(m);
  }
}

// ── Vacío ──────────────────────────────────────────────────────────────────

class _EmptyRecap extends StatelessWidget {
  final ThemeData theme;

  const _EmptyRecap({required this.theme});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.bar_chart_rounded,
            size: 40,
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.recapEmpty,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
