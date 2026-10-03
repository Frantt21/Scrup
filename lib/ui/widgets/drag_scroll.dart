import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Wrapper para filas horizontales: en desktop el ratón NO tiene gesto de
/// arrastre nativo sobre un ListView. Convierte la rueda vertical en scroll
/// horizontal, permite arrastrar con el botón presionado y añade rueda-lateral
/// al recognizer del ListView. En móvil/touch queda todo igual.
class DragScroll extends StatefulWidget {
  const DragScroll({super.key, required this.builder});

  /// Construye el ListView horizontal pasándole el controller compartido.
  final Widget Function(ScrollController controller) builder;

  @override
  State<DragScroll> createState() => _DragScrollState();
}

class _DragScrollState extends State<DragScroll> {
  final ScrollController _controller = ScrollController();
  bool _dragging = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Desplaza el viewport horizontal por [delta] (sin salir de los límites).
  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    if (!pos.hasContentDimensions) return;
    pos.jumpTo(
      (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.basic,
      child: Listener(
        onPointerDown: (d) {
          if (d.buttons & kPrimaryButton == 0) return;
          _dragging = true;
        },
        onPointerMove: (d) {
          if (!_dragging) return;
          // Arrastre con botón presionado: delta horizontal del puntero.
          _scrollBy(-d.delta.dx);
        },
        onPointerUp: (_) => _dragging = false,
        onPointerCancel: (_) => _dragging = false,
        onPointerSignal: (event) {
          // Rueda del ratón: el delta VERTICAL (el normal de un ratón) se
          // convierte en scroll horizontal. El delta horizontal puro (shift+
          // rueda, trackpads) lo gestiona el propio Scrollable: aquí solo
          // actuamos si la rueda fue puramente vertical para no duplicar.
          if (event is! PointerScrollEvent) return;
          if (event.scrollDelta.dx != 0) return;
          _scrollBy(event.scrollDelta.dy);
        },
        child: widget.builder(_controller),
      ),
    );
  }
}

/// ScrollBehavior que habilita el arrastre con ratón/trackpad sobre los
/// Scrollables hijos (el gesto nativo de Flutter ignora el ratón).
class MouseDragScrollBehavior extends MaterialScrollBehavior {
  const MouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

/// ScrollBehavior global de la app.
///
/// Flutter SOLO dibuja el `Scrollbar` en desktop: su `MaterialScrollBehavior`
/// devuelve el hijo tal cual en Android/iOS, así que las listas largas
/// (playlists, álbumes, canciones…) no tenían thumb del que tirar. Además, el
/// scrollbar nativo de Android es NO interactivo (`interactive: false`), de 4px
/// y con un color tenue. Aquí se fuerza en móvil el mismo `Scrollbar` vertical
/// que ya funciona en desktop: aparece al scrollear y **se puede arrastrar**
/// para desplazarse rápido.
///
/// Nota: NO se usa `thumbVisibility: true` a propósito. El shell mantiene varias
/// pantallas vivas en un `IndexedStack` que comparten el `PrimaryScrollController`;
/// un thumb permanente exigiría un controller por scrollable y crashea en debug
/// ("attached to more than one ScrollPosition"). Con la visibilidad por defecto
/// (al scrollear) el resultado es idéntico al de desktop.
class ScrupScrollBehavior extends MaterialScrollBehavior {
  const ScrupScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final direction = details.direction;
    final isVertical =
        direction == AxisDirection.up || direction == AxisDirection.down;
    final platform = getPlatform(context);
    final isMobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    // Desktop y horizontales: comportamiento original (en desktop conserva su
    // scrollbar nativa; el horizontal lo gestiona `DragScroll`).
    if (!isVertical || !isMobile) {
      return super.buildScrollbar(context, child, details);
    }
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        // El thumb nativo de Android usa el `highlightColor` (muy tenue) mientras
        // scrolleas; aquí se le da un tono claro y consistente con la app.
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged)) {
            return onSurface.withValues(alpha: 0.85);
          }
          return onSurface.withValues(alpha: 0.5);
        }),
      ),
      child: Scrollbar(
        controller: details.controller,
        // Arrastrable con el dedo (por defecto en Android es NO interactivo).
        interactive: true,
        thickness: 8,
        radius: const Radius.circular(8),
        child: child,
      ),
    );
  }
}
