import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/artwork_cache_service.dart';
import '../../core/app_log.dart';

/// Renderiza una imagen que puede venir de una URL de red (artwork de
/// YouTube/Deezer) o de un archivo local del dispositivo (portada de
/// playlist elegida por el usuario desde su disco).
///
/// Las URLs de red se persisten en el caché en DISCO
/// ([ArtworkCacheService]): la primera vez se descargan y guardan, y en los
/// siguientes arranques de la app se sirven desde el archivo local — sin
/// re-descargar ni perder los artworks al cerrar y abrir la app.
class CoverImage extends StatefulWidget {
  /// URL `http(s)://` o ruta local absoluta. `null`/vacío muestra el fallback.
  final String? source;
  final Widget fallback;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  const CoverImage({
    super.key,
    required this.source,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
  });

  /// `true` si [source] es una ruta de archivo local (no una URL de red).
  static bool isLocalPath(String source) {
    final lower = source.toLowerCase();
    return !lower.startsWith('http://') && !lower.startsWith('https://');
  }

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  /// Ruta del artwork cacheado en disco (`null` si aún no está cacheado).
  String? _cachedPath;

  /// `true` cuando ya se consultó el caché (evita parpadeos del fallback).
  bool _checked = false;

  /// Descargas de persistencia en curso por URL (dedupe entre instancias).
  static final Map<String, Future<void>> _persisting = {};

  /// Memo url → ruta en disco (estático, sobrevive a remounts): las capas
  /// del player (arte saliente del slide, preview del vecino en el arrastre)
  /// montan un CoverImage NUEVO; sin memo, su primer build pintaba el
  /// fallback (nota musical) hasta que el lookup async del caché terminaba —
  /// el "flash" del icono default en cada cambio/arrastre. Con hit de memo
  /// la primera build YA renderiza Image.file (además, el provider igual
  /// cae en el image cache global de Flutter: decode cero).
  static final Map<String, String> _pathMemo = {};

  @override
  void initState() {
    super.initState();
    final src = widget.source;
    if (src != null &&
        src.isNotEmpty &&
        !CoverImage.isLocalPath(src) &&
        _pathMemo[src] != null) {
      _cachedPath = _pathMemo[src];
      _checked = true;
    }
    _resolve();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      // NO se resetea el estado aquí: mientras se resuelve la fuente nueva
      // se sigue mostrando la imagen ANTERIOR (gapless) — poner _checked=false
      // pintaba el fallback (placeholder con la nota musical) 1+ frames en
      // CADA cambio de pista = el "flash" del artwork default.
      _resolve();
    }
  }

  ArtworkCacheService? _cacheOf(BuildContext context) {
    try {
      return context.read<ArtworkCacheService>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolve() async {
    final src = widget.source;
    if (src == null || src.isEmpty || CoverImage.isLocalPath(src)) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    final cache = _cacheOf(context);
    if (cache == null) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    final path = await cache.filePathFor(src);
    // La fuente pudo cambiar mientras se resolvía: el resultado viejo no
    // debe pisar al de la fuente actual.
    if (!mounted || src != widget.source) return;
    if (path != null) {
      if (_pathMemo.length > 200) _pathMemo.clear();
      _pathMemo[src] = path;
      setState(() {
        _cachedPath = path;
        _checked = true;
      });
    } else {
      setState(() {
        _cachedPath = null;
        _checked = true;
      });
      unawaited(_persistToCache(cache, src));
    }
  }

  /// Descarga y guarda los bytes del artwork en disco (sin bloquear la UI;
  /// si falla, la imagen igual se muestra desde la red).
  Future<void> _persistToCache(ArtworkCacheService cache, String src) {
    final inFlight = _persisting[src];
    if (inFlight != null) return inFlight;
    final future = () async {
      try {
        final resp = await http
            .get(
              Uri.parse(src),
              headers: const {'User-Agent': 'Scrup/0.1 (music player)'},
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          await cache.save(src, resp.bodyBytes);
        }
      } catch (_) {
        // No crítico: la imagen ya se muestra desde red.
      } finally {
        _persisting.remove(src);
      }
    }();
    _persisting[src] = future;
    return future;
  }

  @override
  Widget build(BuildContext context) {
    // EXPERIMENTO kNoArtwork: siempre fallback (sin I/O, descargas,
    // decodes ni subidas a GPU).
    if (kNoArtwork) return widget.fallback;
    final src = widget.source;
    if (src == null || src.isEmpty || !_checked) return widget.fallback;

    // gaplessPlayback: al cambiar de pista conserva el arte anterior hasta
    // que el nuevo decodifica (sin parpadeo a vacío en la transición).
    if (CoverImage.isLocalPath(src)) {
      return Image.file(
        File(src),
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    final cached = _cachedPath;
    if (cached != null) {
      return Image.file(
        File(cached),
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return Image.network(
      src,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}
