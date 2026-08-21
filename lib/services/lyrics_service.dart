import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/lyrics_search_result.dart';
import '../core/synced_lyrics.dart';
import '../data/database.dart';

/// Servicio de letras sincronizadas (multi-proveedor: KPoe → Unison → LRCLIB).
///
/// Busca y cachea las letras de una canción: primero en memoria, luego en
/// Drift (SQLite) y por último en las APIs externas. Intenta obtener lyrics
/// word-by-word (KPoe/Unison) antes de caer a LRCLIB (línea por línea).
class LyricsService {
  LyricsService(this._db);

  final AppDatabase _db;

  final _cache = <String, SyncedLyrics>{};
  final _notFound = <String>{}; // keys ya buscadas sin resultado (sesión)

  /// Busca letras manualmente.
  /// [provider]: 'all' | 'kpoe' | 'lrclib' | 'unison'
  ///
  /// KPoe y Unison exigen título y artista como campos separados (una query
  /// libre en un solo campo responde 400). Para que funcionen desde la
  /// búsqueda manual se generan candidatos (título, artista): primero las
  /// pistas reales de la canción en reproducción ([titleHint]/[artistHint])
  /// y luego particiones heurísticas de la consulta ("A - B", "B by A").
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
            final uri = Uri.parse('$server/v2/lyrics/get').replace(
              queryParameters: {'title': cand.$1, 'artist': cand.$2},
            );
            final response = await http
                .get(uri)
                .timeout(const Duration(seconds: 8));
            if (response.statusCode == 200) {
              final data = json.decode(response.body) as Map<String, dynamic>;
              final lyricsList = data['lyrics'] as List?;
              if (lyricsList != null && lyricsList.isNotEmpty) {
                final metaTitle =
                    (data['metadata']?['title'] as String?) ?? '';
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
                results.add(LyricsSearchResult(
                  id: 0,
                  trackName: metaTitle.isNotEmpty ? metaTitle : cand.$1,
                  artistName: metaArtist.isNotEmpty ? metaArtist : cand.$2,
                  albumName: '',
                  duration: 0.0,
                  synced: true,
                  syncedLyrics: lrcLines.join('\n'),
                  plainLyrics: plainLines.join('\n'),
                ));
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
      final candidates = _searchCandidates(query, titleHint, artistHint);
      outerUnison:
      for (final cand in candidates) {
        try {
          final uri = Uri.parse('https://unison.boidu.dev/lyrics').replace(
            queryParameters: {'song': cand.$1, 'artist': cand.$2},
          );
          final response = await http
              .get(uri)
              .timeout(const Duration(seconds: 8));
          if (response.statusCode == 200) {
            final data = json.decode(response.body) as Map<String, dynamic>;
            if (data['success'] == true && data['data'] != null) {
              final lyricsData = data['data'] as Map<String, dynamic>;
              final lyricsText = lyricsData['lyrics'] as String?;
              if (lyricsText != null && lyricsText.isNotEmpty) {
                // Gate: descarta respuestas (p. ej. TTML) que no parseen
                // como LRC; si no, llegarían resultados vacíos a la UI.
                final parsed = SyncedLyrics.fromLRC(
                  songTitle: cand.$1,
                  artist: cand.$2,
                  lrcContent: lyricsText,
                );
                if (parsed.lines.isEmpty) continue outerUnison;
                results.add(LyricsSearchResult(
                  id: 0,
                  trackName: (lyricsData['song'] as String?) ?? cand.$1,
                  artistName: (lyricsData['artist'] as String?) ?? cand.$2,
                  albumName: '',
                  duration: 0.0,
                  synced: true,
                  syncedLyrics: lyricsText,
                  plainLyrics: parsed.lines.map((l) => l.text).join('\n'),
                ));
                break outerUnison;
              }
            }
          }
        } catch (_) {}
      }
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
            results.add(LyricsSearchResult.fromJson(e as Map<String, dynamic>));
          }
        }
      } catch (_) {}
    }

    return results;
  }

  /// Candidatos (título, artista) para proveedores con campos separados.
  /// Deduplicados y sin pares vacíos. Los hints de la pista actual van
  /// primero (coincidencia exacta); luego las particiones de la query.
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

  /// Milisegundos → timestamp LRC `mm:ss.cc`.
  static String _lrcTs(int ms) {
    final mins = ms ~/ 60000;
    final secs = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10;
    return '${mins.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  /// Guarda unos lyrics seleccionados manualmente (en disco y caché).
  ///
  /// Si el LRC trae palabras con timestamp (tags `<mm:ss.xx>`), se persiste
  /// en el formato karaoke JSON para no perder el modo word-by-word al
  /// reiniciar la app (`toLRC()` de línea los descartaría).
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
      final hasWords =
          lyrics.lines.any((l) => l.words != null && l.words!.isNotEmpty);
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

  /// Busca y devuelve las letras de una canción, o `null` si no se
  /// encontraron (o ya se comprobó antes sin resultado).
  /// Intenta KPoe → Unison → LRCLIB en cascada.
  Future<SyncedLyrics?> fetchLyrics(String title, String artist) async {
    try {
      final cacheKey = _key(title, artist);
      if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
      if (_notFound.contains(cacheKey)) return null;

      // 1) SQLite (getStoredLrc retorna null si isNotFound==true)
      final stored = await _db.getStoredLrc(title, artist);
      if (stored != null) {
        // Check if it's JSON (word-by-word) or plain LRC
        final lyrics = _parseStoredLyrics(stored, title, artist);
        if (lyrics != null) {
          _cache[cacheKey] = lyrics;
          return lyrics;
        }
      }

      // Limpiar título y artista
      final cleanTrack = _cleanTitle(title);
      final cleanArtist = _cleanArtist(artist);

      // ── Try KPoe (word-by-word) ──
      final kpoeResult = await _fetchKpoe(cleanTrack, cleanArtist, title, artist);
      if (kpoeResult != null) {
        // Save as JSON to preserve word-by-word timestamps
        final karaokeJson = _syncedLyricsToJson(kpoeResult);
        await _db.storeLyrics(title, artist, karaokeJson, notFound: false);
        _cache[cacheKey] = kpoeResult;
        return kpoeResult;
      }

      // ── Try Unison (word-by-word or line) ──
      final unisonResult = await _fetchUnison(cleanTrack, cleanArtist, title, artist);
      if (unisonResult != null) {
        _cache[cacheKey] = unisonResult;
        return unisonResult;
      }

      // ── Fallback: LRCLIB (line-by-line) ──
      final lrclibResult = await _fetchLrclib(cleanTrack, cleanArtist, title, artist);
      if (lrclibResult != null) {
        _cache[cacheKey] = lrclibResult;
        return lrclibResult;
      }

      // Sin resultado: marcarlo para no volver a buscar.
      _notFound.add(cacheKey);
      await _db.markLyricsNotFound(title, artist);
      return null;
    } catch (e) {
      return null;
    }
  }

  // ── KPoe API (word-by-word) ───────────────────────────────────────

  static const _kpoeServers = [
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.workers.dev',
  ];

  Future<SyncedLyrics?> _fetchKpoe(
    String cleanTrack, String cleanArtist,
    String originalTitle, String originalArtist,
  ) async {
    final params = {
      'title': cleanTrack,
      'artist': cleanArtist,
    };
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
            final result = _parseKpoeResponse(data, originalTitle, originalArtist);
            if (result != null && result.lines.isNotEmpty) {
              // Store as LRC for cache
              await _db.storeLyrics(
                originalTitle, originalArtist,
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
              words.add(KaraokeWord(
                timestamp: Duration(milliseconds: sylTimeMs),
                text: sylText,
              ));
            }
          }
        }

        if (lineText.trim().isNotEmpty) {
          lines.add(LyricLine(
            timestamp: Duration(milliseconds: lineTimeMs),
            text: lineText.trim(),
            words: words,
          ));
        }
      }

      lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return SyncedLyrics(songTitle: title, artist: artist, lines: lines);
    } catch (_) {
      return null;
    }
  }

  // ── Unison API (word-by-word or line) ──────────────────────────────

  Future<SyncedLyrics?> _fetchUnison(
    String cleanTrack, String cleanArtist,
    String originalTitle, String originalArtist,
  ) async {
    try {
      final params = {
        'song': cleanTrack,
        'artist': cleanArtist,
      };
      final queryStr = params.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');

      final uri = Uri.parse('https://unison.boidu.dev/lyrics?$queryStr');
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['data'] != null) {
          final result = _parseUnisonResponse(data['data'], originalTitle, originalArtist);
          if (result != null && result.lines.isNotEmpty) {
            await _db.storeLyrics(
              originalTitle, originalArtist,
              result.toLRC(),
              notFound: false,
            );
            return result;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  SyncedLyrics? _parseUnisonResponse(
    Map<String, dynamic> data,
    String title,
    String artist,
  ) {
    try {
      final format = (data['format'] as String?)?.toLowerCase() ?? '';
      final lyricsText = data['lyrics'] as String?;
      if (lyricsText == null || lyricsText.isEmpty) return null;

      // If TTML format, try to parse it (Apple Music word-by-word)
      if (format == 'ttml') {
        // For now, fall through to LRC parsing
      }

      // Parse as LRC (works for both 'lrc' format and plain LRC in text)
      return SyncedLyrics.fromLRC(
        songTitle: title,
        artist: artist,
        lrcContent: lyricsText,
      );
    } catch (_) {
      return null;
    }
  }

  // ── LRCLIB API (line-by-line fallback) ─────────────────────────────

  Future<SyncedLyrics?> _fetchLrclib(
    String cleanTrack, String cleanArtist,
    String originalTitle, String originalArtist,
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

            final trackMatches = resultTrackName == searchTrack ||
                _calculateSimilarity(resultTrackName, searchTrack) > 0.5;
            final artistMatches = resultArtistName == searchArtist ||
                _calculateSimilarity(resultArtistName, searchArtist) > 0.5;

            if (!trackMatches || !artistMatches) continue;
            if (syncedLyricsRaw == null || syncedLyricsRaw.trim().isEmpty) continue;

            final lyrics = SyncedLyrics.fromLRC(
              songTitle: originalTitle,
              artist: originalArtist,
              lrcContent: syncedLyricsRaw,
            );

            await _db.storeLyrics(
              originalTitle, originalArtist,
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

  /// Elimina las lyrics guardadas de una canción.
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

  /// Limpia el título (remaster, remix, feats…).
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

  /// Limpia el artista (" - Topic", primeros de lista, etc.).
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

  /// Converts SyncedLyrics to JSON string that preserves word-by-word data.
  String _syncedLyricsToJson(SyncedLyrics lyrics) {
    final linesJson = lyrics.lines.map((line) {
      final lineMap = <String, dynamic>{
        'time': line.timestamp.inMilliseconds,
        'text': line.text,
      };
      if (line.words != null && line.words!.isNotEmpty) {
        lineMap['words'] = line.words!.map((w) => {
          'time': w.timestamp.inMilliseconds,
          'text': w.text,
        }).toList();
      }
      return lineMap;
    }).toList();
    return json.encode({'format': 'karaoke', 'lines': linesJson});
  }

  /// Parses stored lyrics: detects JSON (word-by-word) vs plain LRC.
  SyncedLyrics? _parseStoredLyrics(String stored, String title, String artist) {
    // Try JSON first (word-by-word from KPoe)
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
                  timestamp: Duration(milliseconds: (wd['time'] as num?)?.toInt() ?? 0),
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
    // Fallback: plain LRC
    if (stored.isNotEmpty) {
      return SyncedLyrics.fromLRC(
        songTitle: title,
        artist: artist,
        lrcContent: stored,
      );
    }
    return null;
  }

  /// Similitud de Levenshtein (0..1).
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
