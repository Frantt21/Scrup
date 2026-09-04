import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/artwork_cache_service.dart';

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

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _cachedPath = null;
      _checked = false;
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
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _cachedPath = path;
        _checked = true;
      });
    } else {
      setState(() => _checked = true);
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
    final src = widget.source;
    if (src == null || src.isEmpty || !_checked) return widget.fallback;

    if (CoverImage.isLocalPath(src)) {
      return Image.file(
        File(src),
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
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
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return Image.network(
      src,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}
