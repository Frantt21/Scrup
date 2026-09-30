import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/binaries.dart';
import '../../core/synced_lyrics.dart';
import '../../core/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/palette_cache_store.dart';
import '../../services/player_service.dart';
import '../../services/search_service.dart'
    show SearchService, YtmTrackCredits;
import '../theme_controller.dart';

/// Gap estándar entre cards del now playing (desktop y móvil).
const double kNowPlayingCardGap = 14;

/// Acento canónico del artwork de la pista — la MISMA entrada cacheada que
/// pintan el player y el contenedor de letras (NO una re-derivación del
/// trio, que podría discrepar en los márgenes). Valor derivado del trio solo
/// como fallback legacy.
Color? resolveTrackAccent(BuildContext context, String? artworkUrl) {
  final url = artworkUrl;
  if (url == null || url.isEmpty) return null;
  final store = context.read<PaletteCacheStore>();
  final canonical = store.get(url);
  if (canonical != null) return canonical;
  final trio = store.getTrio(url);
  if (trio == null) return null;
  return ArtworkPaletteService.accentFromTrio(trio);
}

/// Vista previa de letras: línea anterior / actual / siguiente sobre el MISMO
/// fondo plano de acento que el contenedor de letras (acento del artwork +
/// tinta B/N pura por luminancia). Al tocarla se abre el contenedor completo.
class LyricsPreviewCard extends StatelessWidget {
  /// Altura fija de la card, dimensionada de inicio para el peor caso
  /// (línea enfocada envuelta en 3 líneas): dos filas de 1 línea + una
  /// enfocada de 3 + dos gaps de 16px + 8px de aire. Compartida con el
  /// skeleton de carga para que el panel nunca salte al llegar la letra.
  static const double previewHeight =
      (15 * 1.3) * 2 + (18 * 1.3 * 3) + 16 * 2 + 8;

  final SyncedLyrics lyrics;

  /// Índice de línea actual (null = nada activo aún → muestra la línea 0).
  final int? focusIndex;
  final String? artworkUrl;
  final ThemeData theme;
  final VoidCallback? onTap;

  /// Override del acento de fondo. Android lo alimenta con el acento del
  /// [ThemeController] (el MISMO que pinta el sheet de letras del player
  /// expandido) para que card y contenedor se vean idénticos. Desktop no lo
  /// pasa: conserva el acento canónico del artwork ([resolveTrackAccent]).
  final Color? accentColor;

  const LyricsPreviewCard({
    super.key,
    required this.lyrics,
    required this.focusIndex,
    required this.theme,
    this.artworkUrl,
    this.onTap,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? resolveTrackAccent(context, artworkUrl);

    // ANDROID (override activo): la card flota SOBRE el fondo del player,
    // que YA es del color del acento — pintarla con el acento puro la hace
    // invisible. Usa la MISMA receta del sheet de letras del player
    // (_sheetSolidColor): overlay B/N al 10% sobre el acento, y tinta B/N
    // pura igual que el sheet. DESKTOP: acento canónico plano como siempre.
    final bool overridden = accentColor != null;
    final Color bg;
    final Color on;
    if (overridden && accent != null) {
      final dark = ArtworkPaletteService.prefersBlackInk(accent);
      bg = Color.alphaBlend(
        (dark ? Colors.black : Colors.white).withValues(alpha: 0.10),
        accent,
      );
      on = dark ? Colors.black : Colors.white;
    } else {
      bg = accent ?? theme.colorScheme.surfaceContainer;
      on = accent == null
          ? theme.colorScheme.onSurface
          : (ArtworkPaletteService.prefersBlackInk(accent)
                ? Colors.black
                : Colors.white);
    }

    final lines = lyrics.lines;
    final focus = focusIndex ?? 0;
    String? lineAt(int i) =>
        (i >= 0 && i < lines.length) ? lines[i].text : null;
    final prev = lineAt(focus - 1);
    final current = lineAt(focus);
    final next = lineAt(focus + 1);

    // Flujo de texto NATURAL con el ritmo del contenedor principal: las tres
    // líneas mantienen un gap visual CONSTANTE de 16px (el contenedor
    // principal deja ~24px entre cajas de línea) y el grupo se centra
    // verticalmente. La altura de la card es fija para el peor caso de 3
    // líneas: cuando la línea enfocada es corta, el sobrante queda como aire
    // simétrico arriba y abajo — nunca un hueco asimétrico bajo una línea.
    const rowGap = 16.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          width: double.infinity,
          height: previewHeight,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line(prev, on.withValues(alpha: 0.55)),
              const SizedBox(height: rowGap),
              _line(current, on, emphasized: true),
              const SizedBox(height: rowGap),
              _line(next, on.withValues(alpha: 0.55)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String? text, Color color, {bool emphasized = false}) {
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      maxLines: emphasized ? 3 : 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        height: 1.3,
        color: color,
        fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
        fontSize: emphasized ? 18 : 15,
      ),
    );
  }
}

/// Card de créditos: MISMA receta que la de artista (tinte de acento del
/// artwork sobre la superficie del panel, radio 16, mismos paddings).
/// Cabecera + una fila de bullet por crédito, 2 por línea.
class CreditsCard extends StatelessWidget {
  final YtmTrackCredits credits;
  final ThemeData theme;
  final AppLocalizations l10n;

  /// Artwork de la pista actual: fuente del tinte de acento de la card.
  final String? artworkUrl;

  const CreditsCard({
    super.key,
    required this.credits,
    required this.theme,
    required this.l10n,
    this.artworkUrl,
  });

  @override
  Widget build(BuildContext context) {
    final accent = resolveTrackAccent(context, artworkUrl);
    final bg = accent == null
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
        : Color.alphaBlend(
            accent.withValues(alpha: 0.16),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          );

    // Una fila de bullet: punto de 4px + texto (envuelve dentro de la fila).
    Widget bullet(String text, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: icon != null
                    ? Icon(
                        icon,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 6, right: 5),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
              if (icon != null) const SizedBox(width: 7),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.35,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.creditsLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          for (final s in credits.sections) ...[
            // Cabecera de sección: el rol del crédito ("Performed by").
            Text(
              s.role,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final name in s.names) bullet(name),
            const SizedBox(height: 8),
          ],
          if (credits.album != null)
            bullet(credits.album!, icon: Icons.album_rounded),
          if (credits.distributor != null)
            bullet(credits.distributor!, icon: Icons.local_shipping_rounded),
        ],
      ),
    );
  }
}

/// Card de "sin letras" (resultado definitivo): MISMO mensaje que el view de
/// letras (título + hint) en una card de la altura real de la preview.
class NoLyricsCard extends StatelessWidget {
  final ThemeData theme;
  final AppLocalizations l10n;

  const NoLyricsCard({super.key, required this.theme, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: LyricsPreviewCard.previewHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lyrics_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.lyricsNotFound,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.lyricsNotFoundHint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton de carga de la card de letras: EXACTAMENTE la altura real.
class LyricsCardSkeleton extends StatelessWidget {
  final ThemeData theme;

  const LyricsCardSkeleton({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: LyricsPreviewCard.previewHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

/// Skeleton de carga de créditos: cabecera + una sección + 3 bullets.
class CreditsCardSkeleton extends StatelessWidget {
  final ThemeData theme;

  const CreditsCardSkeleton({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    final base = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.12);
    Widget block(double w, double h, {double r = 8}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(r),
          ),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          block(70, 14, r: 6),
          const SizedBox(height: 10),
          block(90, 10, r: 5),
          const SizedBox(height: 4),
          block(double.infinity, 10, r: 5),
          const SizedBox(height: 5),
          block(160, 10, r: 5),
        ],
      ),
    );
  }
}

/// EXTRAS del now playing: card de vista previa de letras + card de créditos
/// de la pista actual, con sus cargas en background (letras vía el singleton
/// [LyricsService] — cacheado, sin requests duplicados con el view de
/// letras — y créditos vía el resolver de [SearchService]).
///
/// REUTILIZADO en dos superficies:
/// - Panel now playing de desktop (antes dentro de [_NowPlayingPanel]).
/// - Player expandido de Android (scrollable, bajo los controles): la card
///   de letras reemplaza al antiguo sheet sobresalido — se entra al
///   contenedor completo tocando la card ([onOpenLyrics]).
class NowPlayingExtras extends StatefulWidget {
  final Track? track;
  final ThemeData theme;
  final AppLocalizations l10n;

  /// Abre el contenedor completo de letras (card tocada).
  final VoidCallback? onOpenLyrics;

  const NowPlayingExtras({
    super.key,
    required this.track,
    required this.theme,
    required this.l10n,
    this.onOpenLyrics,
  });

  @override
  State<NowPlayingExtras> createState() => _NowPlayingExtrasState();
}

class _NowPlayingExtrasState extends State<NowPlayingExtras> {
  /// Letras sincronizadas de la pista actual (el cache de LyricsService lo
  /// hace instantáneo cuando el view de letras ya las buscó).
  SyncedLyrics? _lyrics;

  /// Índice de línea actual, actualizado desde el stream de posición.
  int? _lyricIndex;

  /// Créditos de la pista (panel de descripción WEB `next`). Null mientras
  /// carga o cuando la pista no tiene.
  YtmTrackCredits? _credits;

  /// True mientras el request de créditos está en vuelo (skeleton).
  bool _creditsLoading = false;

  /// True cuando el fetch de letras terminó (encontradas o no): distingue el
  /// skeleton de un resultado definitivo "sin letras".
  bool _lyricsLoaded = false;

  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _loadAll(widget.track);
    _positionSub = context.read<PlayerService>().position.listen((_) {
      if (!mounted) return;
      final lyrics = _lyrics;
      if (lyrics == null) return;
      final idx = lyrics.getCurrentLineIndex(
        context.read<PlayerService>().positionValue,
      );
      if (idx != _lyricIndex) setState(() => _lyricIndex = idx);
    });
  }

  @override
  void didUpdateWidget(NowPlayingExtras old) {
    super.didUpdateWidget(old);
    if (widget.track?.id != old.track?.id) {
      setState(() {
        _lyrics = null;
        _lyricsLoaded = false;
        _lyricIndex = null;
        _credits = null;
        _creditsLoading = false;
      });
      _loadAll(widget.track);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  void _loadAll(Track? t) {
    if (t == null) return;
    _loadLyrics(t);
    _loadCredits(t);
  }

  /// Busca las letras de la pista actual en background (cacheadas tras el
  /// primer fetch — comparte el MISMO singleton LyricsService que el view de
  /// letras, sin requests duplicados).
  Future<void> _loadLyrics(Track t) async {
    try {
      final lyrics = await context
          .read<LyricsService>()
          .fetchLyrics(t.title, t.artist);
      if (!mounted || widget.track?.id != t.id) return;
      setState(() {
        _lyrics = lyrics;
        _lyricsLoaded = true;
        _lyricIndex = lyrics?.getCurrentLineIndex(
          context.read<PlayerService>().positionValue,
        );
      });
    } catch (_) {
      if (mounted && widget.track?.id == t.id) {
        setState(() {
          _lyrics = null;
          _lyricsLoaded = true;
        });
      }
    }
  }

  /// Carga los créditos de la pista actual vía el resolver (diálogo oficial
  /// "Song credits", luego descripción auto-generada, luego fallback de
  /// búsqueda InnerTube para pistas cacheadas sin créditos). Respuestas
  /// tardías de una pista anterior se descartan (guarda por videoId). Fallo
  /// silencioso: sin créditos no se renderiza nada.
  Future<void> _loadCredits(Track t) async {
    final videoId = t.id.trim();
    if (videoId.isEmpty) return;
    if (mounted) setState(() => _creditsLoading = true);
    try {
      final credits = await context
          .read<SearchService>()
          .resolveTrackCredits(videoId, t.title, t.artist);
      if (!mounted || widget.track?.id.trim() != videoId) return;
      setState(() {
        _credits = credits;
        _creditsLoading = false;
      });
    } catch (_) {
      if (mounted && widget.track?.id.trim() == videoId) {
        setState(() {
          _credits = null;
          _creditsLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final l10n = widget.l10n;
    final track = widget.track;
    if (track == null) return const SizedBox.shrink();

    final artworkUrl = track.thumbnailUrl;
    // ANDROID: la card de letras comparte el acento del sheet del player
    // (ThemeController), que es el que pinta el contenedor de letras —
    // antes usaba el acento canónico del artwork y difería del sheet.
    // DESKTOP: sin override → cada card conserva su acento canónico.
    final Color? sheetAccent = Binaries.isMobile
        ? context.watch<ThemeController>().accentColor
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_lyrics != null)
          LyricsPreviewCard(
            lyrics: _lyrics!,
            focusIndex: _lyricIndex,
            artworkUrl: artworkUrl,
            theme: theme,
            onTap: widget.onOpenLyrics,
            accentColor: sheetAccent,
          )
        else if (_lyricsLoaded)
          NoLyricsCard(theme: theme, l10n: l10n)
        else
          LyricsCardSkeleton(theme: theme),
        const SizedBox(height: kNowPlayingCardGap),
        if (_credits != null)
          CreditsCard(
            credits: _credits!,
            theme: theme,
            l10n: l10n,
            artworkUrl: artworkUrl,
          )
        else if (_creditsLoading)
          CreditsCardSkeleton(theme: theme),
      ],
    );
  }
}
