import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/lyrics_search_result.dart';
import '../core/synced_lyrics.dart';

/// Servicio de letras sincronizadas (proveedor: LRCLIB).
///
/// Busca y cachea las letras de una canción: primero en memoria, luego en
/// disco (shared_preferences) y por último en la API de LRCLIB. También
/// recuerda qué canciones ya se buscaron sin resultado para no repetir la
/// llamada de red en cada reproducción.
class LyricsService {
  LyricsService();

  final _cache = <String, SyncedLyrics>{};
  final _notFound = <String>{}; // keys ya buscadas sin resultado (sesión)

  static const _prefLyricsPrefix = 'scrup_lyrics_';
  static const _prefNotFoundPrefix = 'scrup_lyrics_nf_';

  /// Clave estable para una canción (título + artista normalizados).
  String _key(String title, String artist) =>
      '${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}';

  /// Busca letras manualmente devolviendo una lista de resultados.
  Future<List<LyricsSearchResult>> searchLyrics(String query) async {
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=$encodedQuery',
      );

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout searching lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        return results
            .map((e) => LyricsSearchResult.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Guarda unos lyrics seleccionados manualmente (en disco y caché).
  Future<void> saveManualLyrics(
    String songTitle,
    String artist,
    String lrcContent,
  ) async {
    try {
      await _storeLyrics(songTitle, artist, lrcContent, notFound: false);

      final lyrics = SyncedLyrics.fromLRC(
        songTitle: songTitle,
        artist: artist,
        lrcContent: lrcContent,
      );
      _cache[_key(songTitle, artist)] = lyrics;
    } catch (_) {
      // Silencioso: guardar lyrics es best-effort.
    }
  }

  /// Busca y devuelve las letras de una canción, o `null` si no se
  /// encontraron (o ya se comprobó antes sin resultado).
  Future<SyncedLyrics?> fetchLyrics(String title, String artist) async {
    try {
      final cacheKey = _key(title, artist);
      if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
      if (_notFound.contains(cacheKey)) return null;

      final stored = await getStoredLyrics(title, artist);
      if (stored != null) {
        _cache[cacheKey] = stored;
        return stored;
      }

      final alreadyChecked = await _wasStoredNotFound(title, artist);
      if (alreadyChecked) {
        _notFound.add(cacheKey);
        return null;
      }

      // Limpiar título y artista (remaster, "Topic", feats, etc.)
      final cleanTrack = _cleanTitle(title);
      final cleanArtist = _cleanArtist(artist);
      final query = '$cleanTrack $cleanArtist';

      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=$encodedQuery',
      );

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout al descargar lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);

        if (results.isNotEmpty) {
          // Buscar la mejor coincidencia
          for (final item in results) {
            final data = item as Map<String, dynamic>;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            final trackSimilarity = _calculateSimilarity(
              resultTrackName,
              searchTrack,
            );
            final artistSimilarity = _calculateSimilarity(
              resultArtistName,
              searchArtist,
            );

            final trackMatches =
                resultTrackName == searchTrack || trackSimilarity > 0.5;
            final artistMatches =
                resultArtistName == searchArtist || artistSimilarity > 0.5;

            if (!trackMatches || !artistMatches) continue;
            if (syncedLyricsRaw == null || syncedLyricsRaw.trim().isEmpty) {
              continue;
            }

            final lyrics = SyncedLyrics.fromLRC(
              songTitle: title,
              artist: artist,
              lrcContent: syncedLyricsRaw,
            );

            await _storeLyrics(title, artist, syncedLyricsRaw, notFound: false);
            _cache[cacheKey] = lyrics;
            return lyrics;
          }
        }
      }

      // Sin resultado: marcarlo para no volver a buscar.
      _notFound.add(cacheKey);
      await _storeLyrics(title, artist, '', notFound: true);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Obtiene lyrics almacenados localmente (disco).
  Future<SyncedLyrics?> getStoredLyrics(String title, String artist) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lrc = prefs.getString('$_prefLyricsPrefix${_key(title, artist)}');
      if (lrc == null || lrc.isEmpty) return null;
      return SyncedLyrics.fromLRC(
        songTitle: title,
        artist: artist,
        lrcContent: lrc,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _wasStoredNotFound(String title, String artist) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(
            '$_prefNotFoundPrefix${_key(title, artist)}',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _storeLyrics(
    String title,
    String artist,
    String lrcContent, {
    required bool notFound,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(title, artist);
      if (notFound) {
        await prefs.setBool('$_prefNotFoundPrefix$key', true);
        await prefs.remove('$_prefLyricsPrefix$key');
      } else {
        await prefs.setString('$_prefLyricsPrefix$key', lrcContent);
        await prefs.remove('$_prefNotFoundPrefix$key');
      }
    } catch (_) {
      // Silencioso: la persistencia de lyrics es secundaria.
    }
  }

  /// Elimina las lyrics guardadas de una canción.
  Future<void> deleteLyrics(String title, String artist) async {
    try {
      final key = _key(title, artist);
      _cache.remove(key);
      _notFound.remove(key);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefLyricsPrefix$key');
      await prefs.remove('$_prefNotFoundPrefix$key');
    } catch (_) {
      // Silencioso.
    }
  }

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
