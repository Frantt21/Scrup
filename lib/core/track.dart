import 'title_cleaner.dart';

/// Modelo de una pista de audio extraída de YouTube.
class Track {
  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? thumbnailUrl;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
    this.thumbnailUrl,
  });

  factory Track.fromYtDlp(Map<String, dynamic> json) {
    final durationSec = json['duration'];
    final thumbnails = json['thumbnails'] as List<dynamic>?;
    String? thumb;
    if (thumbnails != null && thumbnails.isNotEmpty) {
      // Preferir la última (suele ser la de mayor resolución)
      final sorted = List<Map<String, dynamic>>.from(
        thumbnails.whereType<Map<String, dynamic>>(),
      )..sort((a, b) => ((b['width'] as num?) ?? 0).compareTo((a['width'] as num?) ?? 0));
      thumb = sorted.isNotEmpty ? sorted.first['url'] as String? : null;
    }

    return Track(
      id: json['id'] as String? ?? '',
      // Limpia tags como "(Official Video)", " | Lyrics", etc.
      title: TitleCleaner.clean(json['title'] as String? ?? 'Sin título'),
      artist: (json['channel'] ?? json['uploader'] ?? json['artist'] ?? '') as String? ??
          '',
      duration: durationSec is num && durationSec > 0
          ? Duration(seconds: durationSec.toInt())
          : null,
      thumbnailUrl: thumb,
    );
  }

  /// URL de YouTube canónica para yt-dlp.
  String get youtubeUrl => 'https://www.youtube.com/watch?v=$id';

  Track copyWith({
    String? title,
    String? artist,
    Duration? duration,
    String? thumbnailUrl,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    );
  }
}
