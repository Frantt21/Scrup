/// Adelanto aplicado al calcular la línea actual: la línea se marca como
/// activa 500ms antes de su timestamp para que el highlight no llegue tarde.
/// El sweep karaoke debe completar su última palabra antes de este adelanto
/// (la línea pierde el estado "actual" en nextTs - kCurrentLineAdvance).
const Duration kCurrentLineAdvance = Duration(milliseconds: 500);

/// Palabra con timestamp propio (formato karaoke <mm:ss.xx> de SyncLRC).
class KaraokeWord {
  final Duration timestamp;
  final String text;

  KaraokeWord({required this.timestamp, required this.text});
}

/// Modelo para una línea de letra sincronizada.
class LyricLine {
  final Duration timestamp;
  final String text;
  final List<KaraokeWord>? words;

  LyricLine({required this.timestamp, required this.text, this.words});

  /// `true` si la línea tiene timestamps por palabra (karaoke).
  bool get hasWords => words != null && words!.isNotEmpty;

  /// Crea una LyricLine desde formato LRC: [mm:ss.xx] texto
  factory LyricLine.fromLRC(String line) {
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2})\]\s*(.*)');
    final match = regex.firstMatch(line);

    if (match == null) {
      throw FormatException('Formato LRC inválido: $line');
    }

    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final centiseconds = int.parse(match.group(3)!);
    final fullText = match.group(4)!;

    final timestamp = Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: centiseconds * 10,
    );

    // Palabras con timestamps propios (formato karaoke <mm:ss.xx>)
    List<KaraokeWord>? words;
    final wordRegex = RegExp(r'(?:<(\d{2}):(\d{2})\.(\d{2,3})>)?([^<]+)');
    if (fullText.contains('<')) {
      words = [];
      for (final wMatch in wordRegex.allMatches(fullText)) {
        final wText = wMatch.group(4)!.trimRight();
        if (wText.isEmpty) continue;
        words.add(
          KaraokeWord(
            timestamp: wMatch.group(1) != null
                ? Duration(
                    minutes: int.parse(wMatch.group(1)!),
                    seconds: int.parse(wMatch.group(2)!),
                    milliseconds:
                        int.parse(wMatch.group(3)!) *
                        (wMatch.group(3)!.length == 3 ? 1 : 10),
                  )
                : timestamp,
            text: wText,
          ),
        );
      }
    }

    // Limpiar las etiquetas internas <mm:ss.xx> del texto visible
    var text = fullText.replaceAll(
      RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'),
      '',
    );
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return LyricLine(timestamp: timestamp, text: text, words: words);
  }

  /// Convierte a formato LRC. Con [includeWordTags] emite los timestamps
  /// por palabra como tags karaoke `<mm:ss.cc>palabra` (formato SyncLRC).
  String toLRC({bool includeWordTags = false}) {
    final minutes = timestamp.inMinutes.toString().padLeft(2, '0');
    final seconds = (timestamp.inSeconds % 60).toString().padLeft(2, '0');
    final centiseconds = ((timestamp.inMilliseconds % 1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    final prefix = '[$minutes:$seconds.$centiseconds]';
    if (includeWordTags && hasWords) {
      final parts = <String>[];
      for (final w in words!) {
        final wmins = w.timestamp.inMinutes.toString().padLeft(2, '0');
        final wsecs = (w.timestamp.inSeconds % 60).toString().padLeft(2, '0');
        final wcs =
            ((w.timestamp.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
        parts.add('<$wmins:$wsecs.$wcs>${w.text}');
      }
      return '$prefix ${parts.join(' ')}';
    }
    return '$prefix $text';
  }

  @override
  String toString() => toLRC();
}

/// Modelo completo de letras sincronizadas.
class SyncedLyrics {
  final String songTitle;
  final String artist;
  final List<LyricLine> lines;

  SyncedLyrics({
    required this.songTitle,
    required this.artist,
    required this.lines,
  });

  /// Crea SyncedLyrics desde TTML (Apple Music / Unison richsync): cada
  /// `<p begin="…">` es una línea y cada `<span begin="…">` una palabra.
  factory SyncedLyrics.fromTtml({
    required String songTitle,
    required String artist,
    required String ttmlContent,
  }) {
    final lines = <LyricLine>[];
    final pRegex = RegExp(
      r'<p\b[^>]*?begin="([^"]+)"[^>]*>(.*?)</p>',
      dotAll: true,
      caseSensitive: false,
    );
    final spanRegex = RegExp(
      r'<span\b[^>]*?begin="([^"]+)"[^>]*>(.*?)</span>',
      dotAll: true,
      caseSensitive: false,
    );
    final tagRegex = RegExp(r'<[^>]+>');

    for (final p in pRegex.allMatches(ttmlContent)) {
      final rawBegin = p.group(1);
      if (rawBegin == null) continue;
      final begin = _parseTtmlClock(rawBegin);
      final inner = p.group(2)!;

      final spans = spanRegex.allMatches(inner).toList();
      List<KaraokeWord>? words;
      String text;
      if (spans.isNotEmpty) {
        words = <KaraokeWord>[];
        final buf = StringBuffer();
        for (final s in spans) {
          final rawText = (s.group(2) ?? '').replaceAll(tagRegex, '');
          final clean = _unescapeXml(rawText).replaceAll('\u200b', '').trim();
          if (clean.isEmpty) continue;
          final rawWordBegin = s.group(1);
          words.add(KaraokeWord(
            timestamp: rawWordBegin != null
                ? _parseTtmlClock(rawWordBegin)
                : begin,
            text: clean,
          ));
          buf.write(clean);
          buf.write(' ');
        }
        text = buf.toString().trim();
        if (words.isEmpty) {
          words = null;
          text = _unescapeXml(inner.replaceAll(tagRegex, ''))
              .replaceAll('\u200b', '')
              .trim();
        } else {
          // Los coros de fondo (spans anidados) pueden quedar fuera de
          // orden respecto a los spans principales.
          words.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      } else {
        text = _unescapeXml(inner.replaceAll(tagRegex, ''))
            .replaceAll('\u200b', '')
            .trim();
      }

      if (text.isEmpty) continue;
      lines.add(LyricLine(timestamp: begin, text: text, words: words));
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SyncedLyrics(songTitle: songTitle, artist: artist, lines: lines);
  }

  /// Convierte un reloj TTML (`HH:MM:SS.mmm`, `MM:SS.mmm` o segundos) a
  /// Duration. Acepta separador decimal punto o coma.
  static Duration _parseTtmlClock(String value) {
    var v = value.trim().replaceFirst(',', '.');
    final parts = v.split(':');
    try {
      double seconds;
      if (parts.length >= 3) {
        seconds = int.parse(parts[0]) * 3600 +
            int.parse(parts[1]) * 60 +
            double.parse(parts[2]);
      } else if (parts.length == 2) {
        seconds = int.parse(parts[0]) * 60 + double.parse(parts[1]);
      } else {
        seconds = double.parse(v);
      }
      return Duration(milliseconds: (seconds * 1000).round());
    } catch (_) {
      return Duration.zero;
    }
  }

  static String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  /// Crea SyncedLyrics desde el formato LRC completo.
  factory SyncedLyrics.fromLRC({
    required String songTitle,
    required String artist,
    required String lrcContent,
  }) {
    final lines = <LyricLine>[];

    for (final line in lrcContent.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      try {
        lines.add(LyricLine.fromLRC(trimmed));
      } catch (e) {
        // Ignorar líneas con formato inválido
        continue;
      }
    }

    // Ordenar por timestamp
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return SyncedLyrics(songTitle: songTitle, artist: artist, lines: lines);
  }

  /// Obtiene la línea actual basada en la posición de reproducción.
  LyricLine? getCurrentLine(Duration position) {
    if (lines.isEmpty) return null;

    LyricLine? current;
    for (final line in lines) {
      if (line.timestamp <= position) {
        current = line;
      } else {
        break;
      }
    }
    return current;
  }

  /// Obtiene el índice de la línea actual.
  ///
  /// Para líneas karaoke (con timestamps por palabra) la selección es
  /// EXACTA: el adelanto de [kCurrentLineAdvance] haría que la línea
  /// cambiara antes de que la última palabra terminara de pintarse. El
  /// adelanto solo aplica a líneas sincronizadas por línea, donde compensa
  /// la percepción del highlight.
  int? getCurrentLineIndex(Duration position) {
    if (lines.isEmpty) return null;

    var exact = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timestamp <= position) {
        exact = i;
      } else {
        break;
      }
    }
    if (exact >= 0 && lines[exact].hasWords) return exact;

    final adjustedPosition = position + kCurrentLineAdvance;
    for (int i = lines.length - 1; i >= 0; i--) {
      if (lines[i].timestamp <= adjustedPosition) {
        return i;
      }
    }
    return null;
  }

  /// Convierte a formato LRC completo.
  String toLRC() {
    return lines.map((line) => line.toLRC()).join('\n');
  }

  /// LRC completo conservando los timestamps por palabra (tags karaoke):
  /// útil para transportar lyrics word-by-word como texto.
  String toKaraokeLrc() {
    return lines.map((line) => line.toLRC(includeWordTags: true)).join('\n');
  }

  /// Verifica si tiene letras.
  bool get hasLyrics => lines.isNotEmpty;

  /// Obtiene el número de líneas.
  int get lineCount => lines.length;
}
