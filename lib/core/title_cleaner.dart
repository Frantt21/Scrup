/// Limpia títulos de YouTube eliminando tags de publicación habituales:
/// "(Official Video)", "[HD]", " | Lyrics", "- Audio", etc.
///
/// Intenta conservar el contenido real (nombre de la canción, feats) y solo
/// elimina marcadores de formato/subida.
class TitleCleaner {
  TitleCleaner._();

  static final List<RegExp> _patterns = [
    // Tags entre paréntesis o corchetes en cualquier posición
    RegExp(
      r'[\(\[]([^\)\]]*?(?:official|video|audio|lyrics?|visualizer|remaster(?:ed)?|hd|4k|karaoke|letra)[^\)\]]*?)[\)\]]',
      caseSensitive: false,
    ),
    // Sufijos separados por |, -, –, —, •, · que sean tags (uno o varios
    // consecutivos, p. ej. "- 4K HD" o "| Lyrics - Official Audio")
    RegExp(
      r'\s*[|\-–—•·]\s*(?:(?:official\s+(?:music\s+)?video|official\s+audio|video\s+oficial|lyrics?\s*(?:video)?|audio|visualizer|remaster(?:ed)?|hd|4k|karaoke|letra)\s*(?:[|\-–—•·]\s*)?)+\s*$',
      caseSensitive: false,
    ),
    // Múltiples espacios resultantes
    RegExp(r'\s{2,}'),
  ];

  /// Devuelve el título sin los tags de publicación.
  static String clean(String title) {
    var t = title.trim();
    for (final pattern in _patterns) {
      t = t.replaceAll(pattern, ' ').trim();
    }
    // Limpiar separadores sobrantes al final ("Título - " → "Título")
    t = t.replaceAll(RegExp(r'\s*[|\-–—•·]\s*$'), '').trim();
    return t;
  }
}
