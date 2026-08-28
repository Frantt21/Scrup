// Line becomes active 500ms before its timestamp (highlight anticipation).
const Duration kCurrentLineAdvance = Duration(milliseconds: 500);

class KaraokeWord {
  final Duration timestamp;
  final String text;

  KaraokeWord({required this.timestamp, required this.text});
}

class LyricLine {
  final Duration timestamp;
  final String text;
  final List<KaraokeWord>? words;  final bool conventionEvidence;

  LyricLine({
    required this.timestamp,
    required this.text,
    this.words,
    this.conventionEvidence = false,
  });  bool get hasWords => words != null && words!.isNotEmpty;

  // Parses a [mm:ss.xx] text line, optionally merging syllable tokens.
  factory LyricLine.fromLRC(String line, {bool forceWordGlue = false}) {
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
    );    List<KaraokeWord>? words;
    var evidence = false;
    final wordRegex = RegExp(r'(?:<(\d{2}):(\d{2})\.(\d{2,3})>)?([^<]+)');
    if (fullText.contains('<')) {      final tokens = <({Duration ts, String text, int sepAfter})>[];
      for (final wMatch in wordRegex.allMatches(fullText)) {
        final raw = wMatch.group(4)!;
        final text = raw.trimRight();
        final sepAfter = raw.length - text.length;
        final ts = wMatch.group(1) != null
            ? Duration(
                minutes: int.parse(wMatch.group(1)!),
                seconds: int.parse(wMatch.group(2)!),
                milliseconds:
                    int.parse(wMatch.group(3)!) *
                    (wMatch.group(3)!.length == 3 ? 1 : 10),
              )
            : timestamp;        if (text.isEmpty) {
          if (tokens.isNotEmpty) {
            final p = tokens.removeLast();
            tokens.add((
              ts: p.ts,
              text: p.text,
              sepAfter: p.sepAfter + sepAfter,
            ));
          }
          continue;
        }
        tokens.add((ts: ts, text: text, sepAfter: sepAfter));
      }      evidence =
          tokens.length >= 2 &&
          tokens
              .take(tokens.length - 1)
              .any((t) => t.sepAfter >= 2 || t.sepAfter == 0);
      final conventional = evidence || forceWordGlue;
      final merged = <KaraokeWord>[];
      for (var i = 0; i < tokens.length; i++) {
        final t = tokens[i];
        if (conventional && i > 0 && tokens[i - 1].sepAfter <= 1) {
          final p = merged.removeLast();
          merged.add(
            KaraokeWord(timestamp: p.timestamp, text: p.text + t.text),
          );
        } else {
          merged.add(KaraokeWord(timestamp: t.ts, text: t.text));
        }
      }
      words = merged;
    }    // Clean internal <mm:ss.xx> tags from visible text.
    String text;
    if (words != null && words.isNotEmpty && (evidence || forceWordGlue)) {
      text = words.map((w) => w.text).join(' ');
    } else {
      text = fullText.replaceAll(RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'), '');
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return LyricLine(
      timestamp: timestamp,
      text: text,
      words: words,
      conventionEvidence: evidence,
    );
  }

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
        final wcs = ((w.timestamp.inMilliseconds % 1000) ~/ 10)
            .toString()
            .padLeft(2, '0');
        parts.add('<$wmins:$wsecs.$wcs>${w.text}');
      }
      return '$prefix ${parts.join(' ')}';
    }
    return '$prefix $text';
  }

  @override
  String toString() => toLRC();
}

class SyncedLyrics {
  final String songTitle;
  final String artist;
  final List<LyricLine> lines;

  SyncedLyrics({
    required this.songTitle,
    required this.artist,
    required this.lines,
  });

  // Parses TTML (Apple Music / Unison richsync).
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
          words.add(
            KaraokeWord(
              timestamp: rawWordBegin != null
                  ? _parseTtmlClock(rawWordBegin)
                  : begin,
              text: clean,
            ),
          );
          buf.write(clean);
          buf.write(' ');
        }
        text = buf.toString().trim();
        if (words.isEmpty) {
          words = null;
          text = _unescapeXml(
            inner.replaceAll(tagRegex, ''),
          ).replaceAll('\u200b', '').trim();
        } else {          // Background vocals (nested spans) may be out of order.
          words.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      } else {
        text = _unescapeXml(
          inner.replaceAll(tagRegex, ''),
        ).replaceAll('\u200b', '').trim();
      }

      if (text.isEmpty) continue;
      lines.add(LyricLine(timestamp: begin, text: text, words: words));
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SyncedLyrics(songTitle: songTitle, artist: artist, lines: lines);
  }

  // Parses TTML clock (HH:MM:SS.mmm / MM:SS.mmm / seconds).
  static Duration _parseTtmlClock(String value) {
    var v = value.trim().replaceFirst(',', '.');
    final parts = v.split(':');
    try {
      double seconds;
      if (parts.length >= 3) {
        seconds =
            int.parse(parts[0]) * 3600 +
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

  // Parses complete LRC. Re-parses with forceWordGlue if syllable
  // convention is detected in some lines but not others.
  factory SyncedLyrics.fromLRC({
    required String songTitle,
    required String artist,
    required String lrcContent,
  }) {
    final lines = _parseLrc(lrcContent);

    if (lines.any((l) => l.conventionEvidence) &&
        lines.any((l) => !l.conventionEvidence && l.hasWords)) {
      final glued = _parseLrc(lrcContent, forceWordGlue: true);
      return SyncedLyrics(songTitle: songTitle, artist: artist, lines: glued);
    }

    return SyncedLyrics(songTitle: songTitle, artist: artist, lines: lines);
  }

  static List<LyricLine> _parseLrc(
    String lrcContent, {
    bool forceWordGlue = false,
  }) {
    final lines = <LyricLine>[];

    for (final line in lrcContent.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;      try {
        lines.add(LyricLine.fromLRC(trimmed, forceWordGlue: forceWordGlue));
      } catch (_) {
        continue;
      }
    }    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

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

  // Returns current line index. Karaoke lines use exact matching
  // (no advance) to avoid cutting the last word short.
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

  String toLRC() {
    return lines.map((line) => line.toLRC()).join('\n');
  }

  // LRC with word-level timestamps preserved.
  String toKaraokeLrc() {
    return lines.map((line) => line.toLRC(includeWordTags: true)).join('\n');
  }  bool get hasLyrics => lines.isNotEmpty;  int get lineCount => lines.length;
}
