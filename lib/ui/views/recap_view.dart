import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/track.dart';
import '../../data/database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme_controller.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_bar.dart' show kPlayerClearance;
import '../widgets/screen_header.dart';

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

class _RecapViewState extends State<RecapView> {
  _RecapRange _range = _RecapRange.all;
  bool _loading = true;
  int _totalSeconds = 0;
  List<(Track, int)> _topTracks = const [];
  List<(String, int)> _topArtists = const [];
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
    if (!mounted) return;
    setState(() {
      _totalSeconds = total;
      _topTracks = tracks;
      _topArtists = artists;
      _topPlaylists = playlists;
      _loading = false;
    });
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
                  _TopArtistsCard(theme: theme, accent: accent, items: _topArtists),
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
    // Desktop: fondo transparente, el shell pinta detrás.
    return body;
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
    return SegmentedButton<_RecapRange>(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: accent.withValues(alpha: 0.2),
        selectedForegroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      segments: [
        ButtonSegment(
          value: _RecapRange.all,
          label: Text(l10n.recapRangeAll),
        ),
        ButtonSegment(
          value: _RecapRange.month,
          label: Text(l10n.recapRangeMonth),
        ),
        ButtonSegment(
          value: _RecapRange.week,
          label: Text(l10n.recapRangeWeek),
        ),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
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
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 46,
              height: 46,
              child: CoverImage(
                source: track.thumbnailUrl,
                fit: BoxFit.cover,
                cacheWidth: 92,
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

  const _TopArtistsCard({
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
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 46,
                    height: 46,
                    child: CoverImage(
                      source: items[i].coverUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 92,
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
