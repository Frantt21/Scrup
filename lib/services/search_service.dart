import '../core/track.dart';
import 'ytdlp_service.dart';
import 'ytmusic_service.dart';

/// Búsqueda combinada de Scrup: lanza en paralelo YouTube Music (canciones
/// canónicas con metadatos limpios, vía InnerTube) y YouTube general
/// (yt-dlp), y fusiona los resultados: canciones primero, sin duplicar ids.
/// Si YT Music falla o no devuelve nada, se queda solo con yt-dlp: la
/// búsqueda nunca es peor que antes.
class SearchService {
  SearchService({YtMusicService? ytMusic, YtDlpService? ytDlp})
    : _ytMusic = ytMusic ?? YtMusicService(),
      _ytDlp = ytDlp ?? YtDlpService();

  final YtMusicService _ytMusic;
  final YtDlpService _ytDlp;

  Future<List<Track>> search(String query, {int limit = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    // YT Music tolerante a fallos: cualquier error → lista vacía.
    final songsFuture = _ytMusic
        .search(q, limit: limit)
        .then<List<Track>>(
          (results) => [for (final r in results) r.toTrack()],
          onError: (_) => const <Track>[],
        );

    final [songs, videos] = await Future.wait([
      songsFuture,
      _ytDlp.search(q, limit: limit),
    ]);
    return mergeResults(songs, videos, limit);
  }

  /// Recomendaciones para el modo radio: SOLO YouTube Music (InnerTube).
  /// La consulta suele ser el nombre del artista, y el filtro de canciones
  /// de YT Music devuelve pistas canónicas del artista (sin covers, lives
  /// ni mixes que yt-dlp suele colar). Tolerante a fallos: cualquier error
  /// → lista vacía.
  Future<List<Track>> recommendByArtist(String query, {int limit = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final results = await _ytMusic.search(q, limit: limit);
      return [for (final r in results) r.toTrack()];
    } catch (_) {
      return const [];
    }
  }

  /// Canciones primero y después vídeos generales, descartando ids ya
  /// vistos y capando al límite pedido. Expuesto para tests.
  static List<Track> mergeResults(
    List<Track> songs,
    List<Track> videos,
    int limit,
  ) {
    final out = <Track>[];
    final seen = <String>{};
    for (final t in [...songs, ...videos]) {
      if (t.id.isEmpty || !seen.add(t.id)) continue;
      out.add(t);
      if (out.length >= limit) break;
    }
    return out;
  }
}
