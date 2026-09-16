import 'package:flutter/material.dart';

/// Header FIJO de screen móvil (idéntico al de home): pinned y SIN fondo —
/// el contenido pasa por detrás al scrollear. Título a la izquierda +
/// botones tonales de 40dp a la derecha, hundido con el inset de la barra
/// de estado (pasa 0 si la vista ya vive dentro de un SafeArea superior).
class ScreenHeaderDelegate extends SliverPersistentHeaderDelegate {
  ScreenHeaderDelegate({required this.topInset, required this.child});

  final double topInset;
  final Widget child;

  // MISMA altura de fila que el header de home: el título y los botones
  // quedan a la misma altura visual entre screens.
  static const double _contentH = 64.0;

  @override
  double get minExtent => topInset + _contentH;

  @override
  double get maxExtent => topInset + _contentH;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Sin fondo a propósito (transparente); mismos paddings que home
    // (16 laterales, 16 arriba, 8 abajo).
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topInset + 16, 16, 8),
      child: SizedBox(height: 40, child: child),
    );
  }

  @override
  bool shouldRebuild(ScreenHeaderDelegate oldDelegate) =>
      oldDelegate.topInset != topInset || oldDelegate.child != child;
}

/// Botón tonal de 40dp del header (mismo estilo que el de búsqueda en home).
Widget headerActionButton(
  BuildContext context, {
  required IconData icon,
  VoidCallback? onTap,
  String? tooltip,
}) {
  return SizedBox(
    width: 40,
    height: 40,
    child: IconButton.filledTonal(
      onPressed: onTap,
      icon: Icon(icon),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      tooltip: tooltip,
    ),
  );
}
