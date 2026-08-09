import 'dart:io';

import 'package:flutter/material.dart';

/// Renderiza una imagen que puede venir de una URL de red (artwork de
/// YouTube/Deezer) o de un archivo local del dispositivo (portada de
/// playlist elegida por el usuario desde su disco).
class CoverImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final src = source;
    if (src == null || src.isEmpty) return fallback;

    if (isLocalPath(src)) {
      return Image.file(
        File(src),
        fit: fit,
        width: width,
        height: height,
        cacheWidth: cacheWidth,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Image.network(
      src,
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
