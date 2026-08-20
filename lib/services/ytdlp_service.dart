import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/binaries.dart';
import '../core/track.dart';

/// Excepción de dominio de yt-dlp.
class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  @override
  String toString() => message;
}

/// Reintenta una operación que puede fallar por un archivo bloqueado
/// temporalmente (p. ej. Windows Defender escaneando un .exe recién
/// descargado → ERROR_SHARING_VIOLATION / process_win.cc:577).
/// 
/// Si la excepción contiene "sharing violation", "being used by another
/// process" o "process_win.cc", espera [delay] y reintenta hasta
/// [maxRetries] veces. Otras excepciones se propagan de inmediato.
Future<T> _retryOnSharingViolation<T>(
  Future<T> Function() fn, {
  int maxRetries = 3,
  Duration delay = const Duration(seconds: 2),
}) async {
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt < maxRetries && _isSharingViolation(e)) {
        debugPrint(
          '[yt-dlp] Archivo bloqueado (intento ${attempt + 1}/$maxRetries), '
          'reintentando en ${delay.inSeconds}s...',
        );
        await Future<void>.delayed(delay);
        continue;
      }
      rethrow;
    }
  }
  throw StateError('unreachable');
}

bool _isSharingViolation(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('sharing violation') ||
      msg.contains('being used by another process') ||
      msg.contains('process_win.cc');
}

/// Descarga en streaming de yt-dlp en curso: el audio se escribe en un
/// archivo `.part` que crece mientras se descarga.
///
/// - [playablePath]: resuelve en cuanto el archivo parcial tiene datos
///   suficientes para empezar a reproducir (sin esperar a que termine).
/// - [finalPath]: resuelve al terminar, con la ruta final ya cacheada
///   (yt-dlp renombra el `.part` al nombre definitivo).
/// - [cancel]: mata el proceso.
class StreamingDownload {
  final Future<String> playablePath;
  final Future<String> finalPath;
  final void Function() cancel;

  StreamingDownload({
    required this.playablePath,
    required this.finalPath,
    required this.cancel,
  });
}

/// Servicio que orquesta yt-dlp vía subprocesos:
/// - Búsqueda de pistas (`ytsearchN:query`)
/// - Descarga completa o en streaming (reproducir mientras descarga)
class YtDlpService {
  /// Máximo de consultas cacheadas en memoria (LRU).
  static const int _searchCacheMax = 20;

  /// TTL del caché de búsquedas: el modo radio re-pide recomendaciones del
  /// mismo artista/género con frecuencia, y re-ejecutar yt-dlp (~3s) cada
  /// vez es un desperdicio; con este TTL las repeticiones cercanas son
  /// instantáneas sin volverse obsoletas.
  static const Duration _searchCacheTtl = Duration(minutes: 5);

  /// Caché LRU en memoria de búsquedas recientes (clave = `query|limit`).
  final Map<String, _SearchCacheEntry> _searchCache = {};

  /// Búsquedas en vuelo por clave (dedupe de llamadas concurrentes): el modo
  /// radio puede pedir el mismo artista/género varias veces en paralelo, y
  /// sin esto cada llamada arrancaría su propio proceso yt-dlp (~3s). La
  /// segunda llamada espera el Future de la primera.
  final Map<String, Future<List<Track>>> _searchInflight = {};

  /// Argumentos comunes para descargar el mejor audio de una pista.
  List<String> _downloadArgs(String videoId, String outputDir) {
    return [
      '--no-playlist',
      '--no-warnings',
      '--newline',
      // El mtime debe ser el de la descarga, no la fecha de subida del
      // video, para que la evicción LRU del caché sea correcta.
      '--no-mtime',
      '-f',
      'bestaudio/best',
      '-o',
      p.join(outputDir, '%(id)s.%(ext)s'),
      '--print',
      'after_move:filepath',
      'https://www.youtube.com/watch?v=$videoId',
    ];
  }

  /// Entorno con los directorios de los binarios sidecar añadidos al PATH:
  /// ffmpeg (para remux/merge de yt-dlp) y el directorio de binarios (donde
  /// vive deno, el runtime JS que yt-dlp detecta solo y que mantiene la
  /// extracción de YouTube completa).
  Map<String, String> _envWithSidecars() {
    final env = {...Platform.environment};
    final dirs = Binaries.pathDirs;
    if (dirs.isEmpty) return env;
    final sep = Platform.isWindows ? ';' : ':';
    final path = env['PATH'] ?? '';
    env['PATH'] = '${dirs.join(sep)}$sep$path';
    return env;
  }

  /// Busca en [dir] un archivo parcial (`<videoId>.*.part`) en descarga.
  Future<File?> _findPartial(String dir, String videoId) async {
    final d = Directory(dir);
    if (!await d.exists()) return null;
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    for (final f in files) {
      final name = p.basename(f.path);
      if (name.startsWith('$videoId.') && name.endsWith('.part')) return f;
    }
    return null;
  }

  /// Busca en [dir] el archivo final (`<videoId>.*` sin `.part`).
  Future<String?> _findFinal(String dir, String videoId) async {
    final d = Directory(dir);
    if (!await d.exists()) return null;
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    for (final f in files) {
      final name = p.basename(f.path);
      if (name.startsWith('$videoId.') && !name.endsWith('.part')) {
        return f.path;
      }
    }
    return null;
  }

  /// Ejecuta yt-dlp y devuelve la salida (stdout) o lanza [YtDlpException].
  Future<ProcessResult> _run(
    List<String> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final ytdlp = Binaries.ytdlpPath;
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    debugPrint('[yt-dlp] ${args.join(' ')}');
    final result = await _retryOnSharingViolation(
      () => Process.run(
        ytdlp,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _envWithSidecars(),
      ).timeout(timeout),
    );

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      final out = (result.stdout as String).trim();
      throw YtDlpException(
        err.isNotEmpty ? err : (out.isNotEmpty ? out : 'Error de yt-dlp'),
      );
    }
    return result;
  }

  /// Busca canciones en YouTube. Devuelve lista de [Track].
  ///
  /// Cachea en memoria las consultas recientes (LRU + TTL): el modo radio
  /// pide recomendaciones del mismo artista/género repetidamente y no
  /// conviene re-ejecutar yt-dlp (~3s) en cada petición.
  Future<List<Track>> search(String query, {int limit = 10}) async {
    if (query.trim().isEmpty) return const [];

    final key = '$query|$limit';
    final cached = _searchCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _searchCacheTtl) {
      return cached.tracks;
    }

    // Dedupe de llamadas concurrentes: si ya hay una búsqueda idéntica en
    // vuelo, esperarla en vez de spawnear otro yt-dlp.
    final inflight = _searchInflight[key];
    if (inflight != null) return inflight;

    final future = _doSearch(query, limit);
    _searchInflight[key] = future;
    try {
      final tracks = await future;
      // Almacenar con evicción LRU: si se llenó, descartar la más antigua.
      if (tracks.isNotEmpty) {
        if (_searchCache.length >= _searchCacheMax) {
          String? oldestKey;
          DateTime? oldestAt;
          for (final e in _searchCache.entries) {
            if (oldestAt == null || e.value.at.isBefore(oldestAt)) {
              oldestAt = e.value.at;
              oldestKey = e.key;
            }
          }
          if (oldestKey != null) _searchCache.remove(oldestKey);
        }
        _searchCache[key] = _SearchCacheEntry(tracks, DateTime.now());
      }
      return tracks;
    } finally {
      _searchInflight.remove(key);
    }
  }

  /// Ejecuta yt-dlp para una consulta y parsea los resultados.
  Future<List<Track>> _doSearch(String query, int limit) async {
    final result = await _run([
      'ytsearch$limit:$query',
      '--flat-playlist',
      '--no-warnings',
      '--skip-download',
      '-J',
    ]);

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    } catch (e) {
      throw YtDlpException('No se pudo interpretar la respuesta de yt-dlp.');
    }

    final entries = json['entries'] as List<dynamic>? ?? [];
    final tracks = <Track>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['id'] == null) continue;
      tracks.add(Track.fromYtDlp(entry));
    }
    return tracks;
  }

  /// Descarga en streaming: arranca el proceso y resuelve en cuanto el
  /// archivo `.part` tiene datos suficientes para reproducir (1 MiB, o bien
  /// 6s transcurridos con al menos 64 KiB en conexiones lentas). La descarga
  /// continúa en segundo plano y [StreamingDownload.finalPath] resuelve al
  /// terminar, cuando el `.part` ya se renombró al archivo definitivo.
  ///
  /// Si el proceso se cuelga (red detenida, etc.) se mata a los 10 minutos
  /// para que [StreamingDownload.finalPath] nunca quede sin resolver (un
  /// finalPath colgado bloquearía el slot del caché para siempre).
  Future<StreamingDownload> startStreaming(
    String videoId, {
    required String outputDir,
    String? title,
    void Function(double? percent)? onProgress,
  }) async {
    final ytdlp = Binaries.ytdlpPath;
    if (ytdlp == null) {
      throw YtDlpException(
        'yt-dlp no encontrado. Ejecuta "bash tool/fetch_binaries.sh" '
        'o define SCRUP_YTDLP_PATH.',
      );
    }

    debugPrint('[yt-dlp] stream $videoId');
    final process = await _retryOnSharingViolation(
      () => Process.start(
        ytdlp,
        _downloadArgs(videoId, outputDir),
        environment: _envWithSidecars(),
      ),
    );

    final started = DateTime.now();
    final progressRe = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%');
    // yt-dlp imprime `[download] Destination: <ruta>` cuando empieza a
    // escribir: la ruta EXACTA del `.part`. Con ella el poll es O(1) — se
    // comprueba solo ese archivo en vez de listar todo el directorio caché
    // (que con cientos de pistas era un escaneo O(n) cada 250ms).
    final destinationRe = RegExp(r'\[download\]\s+Destination:\s+(.+)$');
    final partialCompleter = Completer<String>();
    final doneCompleter = Completer<String>();
    var stderr = '';
    var printedPath = '';
    var destinationPath = '';
    var processExited = false;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = progressRe.firstMatch(line);
          if (m != null) {
            onProgress?.call(double.parse(m.group(1)!) / 100);
          }
          final dm = destinationRe.firstMatch(line);
          if (dm != null) {
            destinationPath = dm.group(1)!.trim();
          }
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.contains('[download]')) {
            printedPath = trimmed;
          }
        });
    process.stderr.transform(utf8.decoder).listen((chunk) => stderr += chunk);

    // Vigilar el archivo `.part` hasta que sea reproducible. Con la ruta
    // conocida (Destination) se comprueba un solo archivo; sin ella (p. ej.
    // la salida no lo reportó) se cae al escaneo del directorio una sola vez
    // al final, nunca en bucle.
    Future<void> pollPartial() async {
      const minBytes = 1024 * 1024;
      const timeout = Duration(seconds: 20);
      final deadline = started.add(timeout);
      var known = destinationPath;
      while (DateTime.now().isBefore(deadline)) {
        if (processExited) return;
        if (known.isEmpty) known = destinationPath;
        if (known.isNotEmpty) {
          final f = File(known);
          if (await f.exists()) {
            final size = await f.length();
            final elapsedMs = DateTime.now().difference(started).inMilliseconds;
            if (size >= minBytes || (elapsedMs >= 6000 && size >= 64 * 1024)) {
              if (!partialCompleter.isCompleted) {
                partialCompleter.complete(known);
              }
              return;
            }
          } else {
            // El `.part` ya no existe: la descarga terminó y yt-dlp lo
            // renombró al archivo final (o está en post-proceso/merge).
            // Completar con el archivo final para no esperar al deadline ni
            // reportar un falso error.
            final finalPath = await _findFinal(outputDir, videoId);
            if (finalPath != null) {
              if (!partialCompleter.isCompleted) {
                partialCompleter.complete(finalPath);
              }
              return;
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // Timeout: reproducir con lo que haya, o fallar si no hay nada.
      // Sin ruta conocida se hace UN solo escaneo del directorio (no en
      // bucle): suficiente para los casos en que yt-dlp no reportó destino.
      String? partialPath = known.isNotEmpty && await File(known).exists()
          ? known
          : null;
      if (partialPath == null) {
        final partial = await _findPartial(outputDir, videoId);
        partialPath = partial?.path;
      }
      if (partialPath != null) {
        if (!partialCompleter.isCompleted) {
          partialCompleter.complete(partialPath);
        }
      } else if (!partialCompleter.isCompleted) {
        partialCompleter.completeError(
          YtDlpException(
            'La descarga de "${title ?? videoId}" no generó datos '
            'reproducibles.',
          ),
        );
      }
    }

    unawaited(pollPartial());

    // Esperar al proceso con un tope: si yt-dlp se cuelga, se mata y se
    // completa con error (nunca dejar un finalPath sin resolver).
    unawaited(() async {
      int code;
      try {
        code = await process.exitCode.timeout(const Duration(minutes: 10));
      } on TimeoutException {
        process.kill();
        final err = 'La descarga de "${title ?? videoId}" tardó demasiado.';
        onProgress?.call(null);
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(YtDlpException(err));
        }
        if (!partialCompleter.isCompleted) {
          partialCompleter.completeError(YtDlpException(err));
        }
        return;
      }
      processExited = true;
      if (code == 0) {
        String? finalPath;
        if (printedPath.isNotEmpty && File(printedPath).existsSync()) {
          finalPath = printedPath;
        } else {
          finalPath = await _findFinal(outputDir, videoId);
        }
        if (finalPath == null) {
          final err =
              'La descarga de "${title ?? videoId}" no produjo '
              'un archivo.';
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(YtDlpException(err));
          }
          if (!partialCompleter.isCompleted) {
            partialCompleter.completeError(YtDlpException(err));
          }
        } else {
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete(finalPath);
          }
          if (!partialCompleter.isCompleted) {
            partialCompleter.complete(finalPath);
          }
        }
      } else {
        final err = stderr.trim().isNotEmpty
            ? stderr.trim()
            : 'No se pudo descargar "${title ?? videoId}".';
        onProgress?.call(null);
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(YtDlpException(err));
        }
        if (!partialCompleter.isCompleted) {
          partialCompleter.completeError(YtDlpException(err));
        }
      }
    }());

    return StreamingDownload(
      playablePath: partialCompleter.future,
      finalPath: doneCompleter.future,
      cancel: process.kill,
    );
  }

  /// Extrae metadatos completos de una pista (útil para refrescar el cache).
  ///
  /// Usa el cliente de extracción `android`, que es ~20% más rápido que el
  /// `web` por defecto para SOLO metadatos (medido: 3.4s vs 4.2s). NO debe
  /// usarse para descargas: el cliente android selecciona formatos
  /// progresivos (mp4 con video, ~2.7x más grandes); las descargas siguen
  /// con el cliente web por defecto en [startStreaming].
  Future<Track?> getTrackInfo(String videoId) async {
    final result = await _run([
      '--no-playlist',
      '--no-warnings',
      '--skip-download',
      '--extractor-args',
      'youtube:player_client=android',
      '-J',
      'https://www.youtube.com/watch?v=$videoId',
    ]);
    try {
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      return Track.fromYtDlp(json);
    } catch (_) {
      return null;
    }
  }
}

/// Entrada del caché LRU de búsquedas: resultados + momento del fetch.
class _SearchCacheEntry {
  final List<Track> tracks;
  final DateTime at;

  const _SearchCacheEntry(this.tracks, this.at);
}
