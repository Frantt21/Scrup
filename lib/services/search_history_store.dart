import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Historial PERSISTENTE de búsquedas (un JSON, tope de entradas, sin TTL).
/// Cada búsqueda exitosa sube al frente con dedupe case-insensitive: los
/// chips de la vista Buscar lo muestran y un toque repite la consulta.
class SearchHistoryStore {
  SearchHistoryStore({this.maxEntries = 12, this.directoryOverride});

  final int maxEntries;
  final Directory? directoryOverride;

  final List<String> _mem = [];
  bool _loaded = false;
  Timer? _flushTimer;
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final override = directoryOverride;
    if (override != null) return override;
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'search_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _file(Directory dir) =>
      File(p.join(dir.path, 'search_history.json'));

  /// Carga el historial (UNA vez por sesión; el resto lee memoria).
  Future<List<String>> load() async {
    if (_loaded) return List.unmodifiable(_mem);
    _loaded = true;
    try {
      final dir = await _cacheDir();
      final f = _file(dir);
      if (!await f.exists()) return const [];
      final data = jsonDecode(await f.readAsString());
      if (data is! List) return const [];
      for (final e in data) {
        if (e is String && e.trim().isNotEmpty && !_mem.contains(e)) {
          _mem.add(e);
        }
      }
      while (_mem.length > maxEntries) {
        _mem.removeLast();
      }
    } catch (_) {}
    return List.unmodifiable(_mem);
  }

  /// Añade una consulta (al frente, dedupe case-insensitive) y devuelve la
  /// lista nueva para que la vista refresque los chips.
  Future<List<String>> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return List.unmodifiable(_mem);
    await load();
    _mem.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    _mem.insert(0, q);
    while (_mem.length > maxEntries) {
      _mem.removeLast();
    }
    // Escritura diferida 1s: agrupa ráfagas de búsquedas seguidas.
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_flush());
    });
    return List.unmodifiable(_mem);
  }

  Future<void> _flush() async {
    try {
      final dir = await _cacheDir();
      await _file(dir).writeAsString(jsonEncode(_mem), flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _mem.clear();
    _flushTimer?.cancel();
    try {
      final dir = await _cacheDir();
      final f = _file(dir);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
