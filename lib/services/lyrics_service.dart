import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/lyrics_search_result.dart';
import '../core/synced_lyrics.dart';
import '../data/database.dart';

/// Multi-provider lyrics service: KPoe → Unison → LRCLIB.
/// Tries word-by-word first, falls back to line-by-line.
class LyricsService {
  LyricsService(this._db);

  final AppDatabase _db;

  final _cache = <String, SyncedLyrics>{};  final _notFound = <String>{}; // Keys already searched with no result.  // Searches lyrics manually across all providers.
  Future<List<LyricsSearchResult>> searchLyrics(
    String query, {
    String provider = 'all',
    String? titleHint,
    String? artistHint,
  }) async {
    final results = <LyricsSearchResult>[];
    final wantKpoe = provider == 'all' || provider == 'kpoe';
    final wantLrclib = provider == 'all' || provider == 'lrclib';
    final wantUnison = provider == 'all' || provider == 'unison';

    // Try KPoe first (word-by-word)
    if (wantKpoe) {
      final candidates = _searchCandidates(query, titleHint, artistHint);
      outerKpoe:
      for (final server in _kpoeServers) {
        for (final cand in candidates) {
          try {
            final uri = Uri.parse(
              '$server/v2/lyrics/get',
            ).replace(queryParameters: {'title': cand.$1, 'artist': cand.$2});
            final response = await http
                .get(uri)
                .timeout(const Duration(seconds: 8));
            if (response.statusCode == 200) {
              final data = json.decode(response.body) as Map<String, dynamic>;
              final lyricsList = data['lyrics'] as List?;
              if (lyricsList != null && lyricsList.isNotEmpty) {
                final metaTitle = (data['metadata']?['title'] as String?) ?? '';
                final metaArtist =
                    (data['metadata']?['artist'] as String?) ?? '';
                // LRC con tags <mm:ss.xx> por sílaba: preserva el modo
                // word-by-word al aplicar/guardar el resultado manual.
                final lrcLines = <String>[];
                final plainLines = <String>[];
                for (final item in lyricsList) {
                  final ld = item as Map<String, dynamic>;
                  final t = (ld['time'] as num?)?.toInt() ?? 0;
                  final text = ((ld['text'] as String?) ?? '').trim();
                  final syllabus = ld['syllabus'] as List?;
                  var line = '[${_lrcTs(t)}]';
                  var hasWords = false;
                  if (syllabus != null && syllabus.isNotEmpty) {
                    final words = <String>[];
                    for (final syl in syllabus) {
                      final sd = syl as Map<String, dynamic>;
                      final st = (sd['time'] as num?)?.toInt() ?? 0;
                      final stext = (sd['text'] as String?) ?? '';
                      if (stext.isEmpty) continue;
                      words.add('<${_lrcTs(st)}>$stext');
                    }
                    if (words.isNotEmpty) {
                      line += ' ${words.join(' ')}';
                      hasWords = true;
                    }
                  }
                  if (!hasWords) line += ' $text';
                  lrcLines.add(line);
                  plainLines.add(text);
                }
                results.add(
                  LyricsSearchResult(
                    id: 0,
                    trackName: metaTitle.isNotEmpty ? metaTitle : cand.$1,
                    artistName: metaArtist.isNotEmpty ? metaArtist : cand.$2,
                    albumName: '',
                    duration: 0.0,
                    synced: true,
                    syncedLyrics: lrcLines.join('\n'),
                    plainLyrics: plainLines.join('\n'),
                    provider: 'KPoe',
                  ),
                );
                break outerKpoe;
              }
            }
          } catch (e) {
            //
            continue;
          }
        }
      }
    }

    // Try Unison
    if (wantUnison) {
      // 1) Lookup exacto song+artist con los candidatos (preciso).
      LyricsSearchResult? unison;
      final candidates = _searchCandidates(query, titleHint, artistHint);
      for (final cand in candidates) {
        unison = await _unisonExactLookup(cand.$1, cand.$2);
        if (unison != null) break;
      }
      // 2) Fallback: búsqueda full-text (acepta la query libre) y
      //    descarga del cuerpo de los mejores candidatos por id.
      unison ??= await _unisonSearchLookup(query);
      if (unison != null) results.add(unison);
    }

    // Try LRCLIB (line-by-line)
    if (wantLrclib) {
      try {
        final encodedQuery = Uri.encodeComponent(query);
        final uri = Uri.parse('https://lrclib.net/api/search?q=$encodedQuery');
        final response = await http
            .get(uri)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => throw Exception('Timeout searching lyrics'),
            );
        if (response.statusCode == 200) {
          final List lrclibResults = json.decode(response.body);
          for (final e in lrclibResults) {
            results.add(
              LyricsSearchResult.fromJson(
                e as Map<String, dynamic>,
                provider: 'LRCLIB',
              ),
            );
          }
        }
      } catch (_) {}
    }

    return results;
  }  // Generates (title, artist) candidates for providers with separate fields.
  static List<(String, String)> _searchCandidates(
    String query,
    String? titleHint,
    String? artistHint,
  ) {
    final candidates = <(String, String)>[];
    void add(String t, String a) {
      t = t.trim();
      a = a.trim();
      if (t.isEmpty || a.isEmpty) return;
      final pair = (t.toLowerCase(), a.toLowerCase());
      for (final c in candidates) {
        if (c.$1.toLowerCase() == pair.$1 && c.$2.toLowerCase() == pair.$2) {
          return;
        }
      }
      candidates.add((t, a));
    }

    if (titleHint != null && titleHint.trim().isNotEmpty) {
      add(titleHint, artistHint ?? '');
    }
    final q = query.trim();
    // "Artista - Título" / "Título - Artista"
    final dashParts = q.split(RegExp(r'\s+[-–—]\s+'));
    if (dashParts.length == 2) {
      add(dashParts[0], dashParts[1]);
      add(dashParts[1], dashParts[0]);
    }
    // "Título by Artista"
    final byMatch = RegExp(
      r'^(.*?)\s+by\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(q);
    if (byMatch != null) {
      add(byMatch.group(1)!, byMatch.group(2)!);
    }
    return candidates;
  }

  static String _lrcTs(int ms) {
    final mins = ms ~/ 60000;
    final secs = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10;
    return '${mins.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }  // Saves manually selected lyrics, preserving word-by-word if present.
  Future<void> saveManualLyrics(
    String songTitle,
    String artist,
    String lrcContent,
  ) async {
    try {
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: songTitle,
        artist: artist,
        lrcContent: lrcContent,
      );
      final hasWords = lyrics.lines.any(
        (l) => l.words != null && l.words!.isNotEmpty,
      );
      await _db.storeLyrics(
        songTitle,
        artist,
        hasWords ? _syncedLyricsToJson(lyrics) : lrcContent,
        notFound: false,
      );
      _cache[_key(songTitle, artist)] = lyrics;
    } catch (_) {
      // Silencioso: guardar lyrics es best-effort.
    }
  }

  // Fetches lyrics: KPoe → Unison → LRCLIB, with SQLite cache.
  Future<SyncedLyrics?> fetchLyrics(String title, String artist) async {
    try {
      final cacheKey = _key(title, artist);
      if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
      if (_notFound.contains(cacheKey)) return null;      final stored = await _db.getStoredLrc(title, artist);
      if (stored != null) {
        // Check if it's JSON (word-by-word) or plain LRC
        final lyrics = _parseStoredLyrics(stored, title, artist);
        if (lyrics != null) {
          _cache[cacheKey] = lyrics;
          return lyrics;
        }
      }      final cleanTrack = _cleanTitle(title);      final cleanArtist = _cleanArtist(artist);

      final kpoeResult = await _fetchKpoe(
        cleanTrack,
        cleanArtist,
        title,
        artist,
      );
      if (kpoeResult != null) {
        // Save as JSON to preserve word-by-word timestamps
        final karaokeJson = _syncedLyricsToJson(kpoeResult);
        await _db.storeLyrics(title, artist, karaokeJson, notFound: false);
        _cache[cacheKey] = kpoeResult;
        return kpoeResult;
      }

      final unisonResult = await _fetchUnison(
        cleanTrack,
        cleanArtist,
        title,
        artist,
      );
      if (unisonResult != null) {
        _cache[cacheKey] = unisonResult;
        return unisonResult;
      }

      final lrclibResult = await _fetchLrclib(
        cleanTrack,
        cleanArtist,
        title,
        artist,
      );
      if (lrclibResult != null) {
        _cache[cacheKey] = lrclibResult;
        return lrclibResult;
      }      _notFound.add(cacheKey);
      await _db.markLyricsNotFound(title, artist);
      return null;
    } catch (e) {
      return null;
    }
  }  // ── KPoe ─────────────────────────────────────────────────────────────

  static const _kpoeServers = [
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.workers.dev',
  ];

  Future<SyncedLyrics?> _fetchKpoe(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    final params = {'title': cleanTrack, 'artist': cleanArtist};
    final queryStr = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');

    for (final server in _kpoeServers) {
      try {
        final uri = Uri.parse('$server/v2/lyrics/get?$queryStr');
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          final lyrics = data['lyrics'] as List?;
          if (lyrics != null && lyrics.isNotEmpty) {
            final result = _parseKpoeResponse(
              data,
              originalTitle,
              originalArtist,
            );
            if (result != null && result.lines.isNotEmpty) {
              // Store as LRC for cache
              await _db.storeLyrics(
                originalTitle,
                originalArtist,
                result.toLRC(),
                notFound: false,
              );
              return result;
            }
          }
        }
      } catch (_) {
        continue; // Try next server
      }
    }
    return null;
  }

  SyncedLyrics? _parseKpoeResponse(
    Map<String, dynamic> data,
    String title,
    String artist,
  ) {
    try {
      final lyricsList = data['lyrics'] as List;
      final lines = <LyricLine>[];

      for (final item in lyricsList) {
        final lineData = item as Map<String, dynamic>;
        final lineTimeMs = (lineData['time'] as num?)?.toInt() ?? 0;
        final lineText = (lineData['text'] as String?) ?? '';
        final syllabus = lineData['syllabus'] as List?;

        List<KaraokeWord>? words;
        if (syllabus != null && syllabus.isNotEmpty) {
          words = [];
          for (final syl in syllabus) {
            final sylData = syl as Map<String, dynamic>;
            final sylText = (sylData['text'] as String?) ?? '';
            final sylTimeMs = (sylData['time'] as num?)?.toInt() ?? 0;
            if (sylText.isNotEmpty) {
              words.add(
                KaraokeWord(
                  timestamp: Duration(milliseconds: sylTimeMs),
                  text: sylText,
                ),
              );
            }
          }
        }

        if (lineText.trim().isNotEmpty) {
          lines.add(
            LyricLine(
              timestamp: Duration(milliseconds: lineTimeMs),
              text: lineText.trim(),
              words: words,
            ),
          );
        }
      }

      lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return SyncedLyrics(songTitle: title, artist: artist, lines: lines);
    } catch (_) {
      return null;
    }
  }

  // ── Unison ───────────────────────────────────────────────────────────

  Future<SyncedLyrics?> _fetchUnison(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    try {
      final params = {'song': cleanTrack, 'artist': cleanArtist};
      final queryStr = params.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');

      final uri = Uri.parse('https://unison.boidu.dev/lyrics?$queryStr');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['data'] is Map) {
          final record = data['data'] as Map<String, dynamic>;
          final lyricsText = record['lyrics'] as String?;
          if (lyricsText != null && lyricsText.isNotEmpty) {
            final format = ((record['format'] as String?) ?? '').toLowerCase();
            final parsed = format == 'ttml'
                ? SyncedLyrics.fromTtml(
                    songTitle: originalTitle,
                    artist: originalArtist,
                    ttmlContent: lyricsText,
                  )
                : SyncedLyrics.fromLRC(
                    songTitle: originalTitle,
                    artist: originalArtist,
                    lrcContent: lyricsText,
                  );
            if (parsed.lines.isNotEmpty) {
              // JSON karaoke si hay palabras; LRC de línea si no.
              final hasWords = parsed.lines.any((l) => l.hasWords);
              await _db.storeLyrics(
                originalTitle,
                originalArtist,
                hasWords ? _syncedLyricsToJson(parsed) : parsed.toLRC(),
                notFound: false,
              );
              return parsed;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }  // ── Unison search helpers ────────────────────────────────────────────

  Future<LyricsSearchResult?> _unisonExactLookup(
    String song,
    String artist,
  ) async {
    try {
      final uri = Uri.parse(
        'https://unison.boidu.dev/lyrics',
      ).replace(queryParameters: {'song': song, 'artist': artist});
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['success'] != true || data['data'] is! Map) return null;
      return _unisonRecordToResult(data['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<LyricsSearchResult?> _unisonSearchLookup(String query) async {
    try {
      final uri = Uri.parse(
        'https://unison.boidu.dev/lyrics/search',
      ).replace(queryParameters: {'q': query, 'limit': '3'});
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['success'] != true || data['data'] is! List) return null;
      for (final entry in (data['data'] as List).take(3)) {
        if (entry is! Map) continue;
        final id = entry['id'];
        if (id == null) continue;
        try {
          final recUri = Uri.parse('https://unison.boidu.dev/lyrics/$id');
          final recResponse = await http
              .get(recUri)
              .timeout(const Duration(seconds: 8));
          if (recResponse.statusCode != 200) continue;
          final recData = json.decode(recResponse.body) as Map<String, dynamic>;
          if (recData['success'] != true || recData['data'] is! Map) continue;
          final result = _unisonRecordToResult(
            recData['data'] as Map<String, dynamic>,
          );
          if (result != null) return result;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
    return null;
  }

  LyricsSearchResult? _unisonRecordToResult(Map<String, dynamic> record) {
    final lyricsText = record['lyrics'] as String?;
    if (lyricsText == null || lyricsText.isEmpty) return null;
    final format = ((record['format'] as String?) ?? '').toLowerCase();
    final song = (record['song'] as String?) ?? '';
    final artist = (record['artist'] as String?) ?? '';

    final SyncedLyrics parsed;
    if (format == 'ttml') {
      parsed = SyncedLyrics.fromTtml(
        songTitle: song,
        artist: artist,
        ttmlContent: lyricsText,
      );
    } else {
      parsed = SyncedLyrics.fromLRC(
        songTitle: song,
        artist: artist,
        lrcContent: lyricsText,
      );
    }

    if (parsed.lines.isEmpty) {
      if (format == 'plain') {
        return LyricsSearchResult(
          id: (record['id'] as num?)?.toInt() ?? 0,
          trackName: song,
          artistName: artist,
          albumName: (record['album'] as String?) ?? '',
          duration: (record['duration'] as num?)?.toDouble() ?? 0.0,
          synced: false,
          syncedLyrics: '',
          plainLyrics: lyricsText,
          provider: 'Unison',
        );
      }
      return null;
    }

    return LyricsSearchResult(
      id: (record['id'] as num?)?.toInt() ?? 0,
      trackName: song,
      artistName: artist,
      albumName: (record['album'] as String?) ?? '',
      duration: (record['duration'] as num?)?.toDouble() ?? 0.0,
      synced: format != 'plain',
      syncedLyrics: parsed.toKaraokeLrc(),
      plainLyrics: parsed.lines.map((l) => l.text).join('\n'),
      provider: 'Unison',
    );
  }

  // ── LRCLIB ──────────────────────────────────────────────────────────

  Future<SyncedLyrics?> _fetchLrclib(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    try {
      final query = '$cleanTrack $cleanArtist';
      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse('https://lrclib.net/api/search?q=$encodedQuery');

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout al descargar lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);

        if (results.isNotEmpty) {
          for (final item in results) {
            final data = item as Map<String, dynamic>;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            final trackMatches =
                resultTrackName == searchTrack ||
                _calculateSimilarity(resultTrackName, searchTrack) > 0.5;
            final artistMatches =
                resultArtistName == searchArtist ||
                _calculateSimilarity(resultArtistName, searchArtist) > 0.5;

            if (!trackMatches || !artistMatches) continue;
            if (syncedLyricsRaw == null || syncedLyricsRaw.trim().isEmpty) {
              continue;
            }

            final lyrics = SyncedLyrics.fromLRC(
              songTitle: originalTitle,
              artist: originalArtist,
              lrcContent: syncedLyricsRaw,
            );

            await _db.storeLyrics(
              originalTitle,
              originalArtist,
              syncedLyricsRaw,
              notFound: false,
            );
            return lyrics;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> deleteLyrics(String title, String artist) async {
    try {
      final key = _key(title, artist);
      _cache.remove(key);
      _notFound.remove(key);
      await _db.deleteLyrics(title, artist);
    } catch (_) {
      // Silencioso.
    }
  }

  // ---------------------------------------------------------------- helpers
  String _key(String title, String artist) =>
      '${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}';

  // Strips remaster/remix/feat tags from title.
  String _cleanTitle(String title) {
    String clean = title;
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Remaster(ed)?\s*\d*', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\(Remaster(ed)?\s*\d*\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[Remaster(ed)?\s*\d*\]', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\(.*?(?:Remix|Version|Edit|Mix).*?\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[.*?(?:Remix|Version|Edit|Mix).*?\]', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(
        r'\s+(?:ft\.?|feat\.?|featuring|con|with)\s+.*',
        caseSensitive: false,
      ),
      '',
    );
    return clean.trim();
  }

  // Strips "- Topic" and similar suffixes from artist.
  String _cleanArtist(String artist) {
    String clean = artist;
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false),
      '',
    );
    final match = RegExp(r'^([^,&]+)').firstMatch(clean);
    if (match != null) {
      clean = match.group(1) ?? clean;
    }
    return clean.trim();
  }

  // ── JSON serialization for word-by-word preservation ────────────────

  String _syncedLyricsToJson(SyncedLyrics lyrics) {
    final linesJson = lyrics.lines.map((line) {
      final lineMap = <String, dynamic>{
        'time': line.timestamp.inMilliseconds,
        'text': line.text,
      };
      if (line.words != null && line.words!.isNotEmpty) {
        lineMap['words'] = line.words!
            .map((w) => {'time': w.timestamp.inMilliseconds, 'text': w.text})
            .toList();
      }
      return lineMap;
    }).toList();
    return json.encode({'format': 'karaoke', 'lines': linesJson});
  }

  // Parses stored lyrics: JSON (word-by-word) vs plain LRC.
  SyncedLyrics? _parseStoredLyrics(String stored, String title, String artist) {
    if (stored.startsWith('{')) {
      try {
        final data = json.decode(stored) as Map<String, dynamic>;
        if (data['format'] == 'karaoke' && data['lines'] != null) {
          final linesList = data['lines'] as List;
          final lines = linesList.map((l) {
            final lineData = l as Map<String, dynamic>;
            final timeMs = (lineData['time'] as num?)?.toInt() ?? 0;
            final text = (lineData['text'] as String?) ?? '';
            final wordsData = lineData['words'] as List?;
            List<KaraokeWord>? words;
            if (wordsData != null && wordsData.isNotEmpty) {
              words = wordsData.map((w) {
                final wd = w as Map<String, dynamic>;
                return KaraokeWord(
                  timestamp: Duration(
                    milliseconds: (wd['time'] as num?)?.toInt() ?? 0,
                  ),
                  text: (wd['text'] as String?) ?? '',
                );
              }).toList();
            }
            return LyricLine(
              timestamp: Duration(milliseconds: timeMs),
              text: text,
              words: words,
            );
          }).toList();
          lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          return SyncedLyrics(songTitle: title, artist: artist, lines: lines);
        }
      } catch (_) {}
    }
    if (stored.isNotEmpty) {
      return SyncedLyrics.fromLRC(
        songTitle: title,
        artist: artist,
        lrcContent: stored,
      );
    }
    return null;
  }

  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final len1 = s1.length;
    final len2 = s2.length;
    final maxLen = len1 > len2 ? len1 : len2;
    final matrix = List.generate(len1 + 1, (i) => List.filled(len2 + 1, 0));
    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }
    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return 1.0 - (matrix[len1][len2] / maxLen);
  }
}
