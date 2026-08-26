import 'title_cleaner.dart';

/// Modelo de una pista de audio extraída de YouTube.
class Track {
  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? thumbnailUrl;

  /// Álbum al que pertenece la pista (rellenado por el enriquecimiento de
  /// metadatos vía Deezer; los resultados de YouTube no lo traen).
  final String? album;

  /// `true` si los metadatos ya vienen limpios de origen (YT Music/InnerTube
  /// con filtro Songs): el enriquecimiento Deezer NO debe sobreescribirlos
  /// con su matching difuso. No se serializa: es proveniencia en memoria.
  final bool cleanMetadata;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
    this.thumbnailUrl,
    this.album,
    this.cleanMetadata = false,
  });

  factory Track.fromYtDlp(Map<String, dynamic> json) {
    final durationSec = json['duration'];
    final thumbnails = json['thumbnails'] as List<dynamic>?;
    String? thumb;
    if (thumbnails != null && thumbnails.isNotEmpty) {
      // Preferir la última (suele ser la de mayor resolución)
      final sorted =
          List<Map<String, dynamic>>.from(
            thumbnails.whereType<Map<String, dynamic>>(),
          )..sort(
            (a, b) => ((b['width'] as num?) ?? 0).compareTo(
              (a['width'] as num?) ?? 0,
            ),
          );
      thumb = sorted.isNotEmpty ? sorted.first['url'] as String? : null;
    }

    return Track(
      id: json['id'] as String? ?? '',
      // Limpia tags como "(Official Video)", " | Lyrics", etc.
      title: TitleCleaner.clean(json['title'] as String? ?? 'Sin título'),
      artist:
          (json['channel'] ?? json['uploader'] ?? json['artist'] ?? '')
              as String? ??
          '',
      duration: durationSec is num && durationSec > 0
          ? Duration(seconds: durationSec.toInt())
          : null,
      thumbnailUrl: thumb,
      album: json['album'] as String?,
    );
  }

  /// URL de YouTube canónica para yt-dlp.
  String get youtubeUrl => 'https://www.youtube.com/watch?v=$id';

  /// Variante de MÁXIMA resolución para thumbnails de YouTube:
  /// - `i.ytimg.com/vi/<id>/<variante>.jpg` → `maxresdefault.jpg` (1280px).
  /// - Miniaturas de YT Music (`googleusercontent.com`): traen el tamaño en
  ///   el sufijo (`=w544-h544-l90-rj`); pedir la variante a 1200px — la
  ///   imagen base suele ser ≥1200 y a ese tamaño se ve nítida en fullscreen.
  /// Puede devolver una URL que responda 404 si no existe esa resolución: el
  /// llamador debe degradar al original (la cadena de respaldo del player).
  static String? hiResThumbnail(String? url) {
    if (url == null || url.isEmpty) return null;
    final m = RegExp(r'i\.ytimg\.com/vi/([\w-]+)').firstMatch(url);
    if (m != null) {
      return 'https://i.ytimg.com/vi/${m.group(1)!}/maxresdefault.jpg';
    }
    if (url.contains('googleusercontent.com')) {
      return url.replaceFirst(RegExp(r'=(w|s)\d+.*$'), '=w1200-h1200');
    }
    return url;
  }

  Track copyWith({
    String? title,
    String? artist,
    Duration? duration,
    String? thumbnailUrl,
    String? album,
    bool? cleanMetadata,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      album: album ?? this.album,
      cleanMetadata: cleanMetadata ?? this.cleanMetadata,
    );
  }
}
