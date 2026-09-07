/// Clean YouTube titles by removing common publication tags:
/// "(Official Video)", "[HD]", " | Lyrics", "- Audio", etc.
///
/// It tries to keep the real content (song name, feats) and only removes
/// format/upload markers.
class TitleCleaner {
  TitleCleaner._();

  static final List<RegExp> _patterns = [
    // Tags in parentheses or brackets at any position
    RegExp(
      r'[\(\[]([^\)\]]*?(?:official|video|audio|lyrics?|visualizer|remaster(?:ed)?|hd|4k|karaoke|letra)[^\)\]]*?)[\)\]]',
      caseSensitive: false,
    ),
    // Suffixes separated by |, -, –, —, •, · that are tags (one or more
    // consecutive, e.g. "- 4K HD" or "| Lyrics - Official Audio")
    RegExp(
      r'\s*[|\-–—•·]\s*(?:(?:official\s+(?:music\s+)?video|official\s+audio|video\s+oficial|lyrics?\s*(?:video)?|audio|visualizer|remaster(?:ed)?|hd|4k|karaoke|letra)\s*(?:[|\-–—•·]\s*)?)+\s*$',
      caseSensitive: false,
    ),
    // Multiple resulting spaces
    RegExp(r'\s{2,}'),
  ];

  /// Devuelve el título sin los tags de publicación.
  static String clean(String title) {
    var t = title.trim();
    for (final pattern in _patterns) {
      t = t.replaceAll(pattern, ' ').trim();
    }
    // Clean leftover separators at the end ("Title - " -> "Title")
    t = t.replaceAll(RegExp(r'\s*[|\-–—•·]\s*$'), '').trim();
    return t;
  }
}
