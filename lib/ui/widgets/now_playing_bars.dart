import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Ecualizador animado: indica que una pista se está reproduciendo (barras
/// en movimiento) o está pausada (barras bajas y quietas).
///
/// Cuatro barras redondeadas cuyo alto oscila con ondas desfasadas entre sí.
/// Solo anima cuando [active] es true: el resto de instancias (filas que no
/// son la actual) quedan estáticas y sin coste de frames. El color por
/// defecto es el acento del tema (lila, o el de la playlist en el detalle).
class NowPlayingBars extends StatefulWidget {
  /// `true` = animación en marcha (pista reproduciéndose); `false` = barras
  /// estáticas (pista pausada o estado inactivo).
  final bool active;

  /// Altura total del ecualizador (el ancho se deduce de la proporción).
  final double size;

  /// Color de las barras; por defecto el `primary` del tema.
  final Color? color;

  const NowPlayingBars({
    super.key,
    this.active = true,
    this.size = 18,
    this.color,
  });

  @override
  State<NowPlayingBars> createState() => _NowPlayingBarsState();
}

class _NowPlayingBarsState extends State<NowPlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant NowPlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color ?? theme.colorScheme.primary;
    final barWidth = widget.size * 0.16;
    final gap = widget.size * 0.11;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return SizedBox(
          width: barWidth * 4 + gap * 4,
          height: widget.size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: gap / 2),
                  child: _bar(t, i, barWidth, color),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Una barra: alto entre 35% y 100% del tamaño, según una onda senoidal
  /// desfasada por índice. Estática en 35% cuando no hay reproducción.
  /// Sombra negra sutil para que el ecualizador se lea sobre cualquier
  /// artwork (las tarjetas lo muestran sin chip de fondo).
  Widget _bar(double t, int i, double width, Color color) {
    final phase = (t * 2 * math.pi) + (i * 0.9);
    final fraction = widget.active
        ? 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase))
        : 0.35;
    return Container(
      width: width,
      height: widget.size * fraction,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(width / 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 2),
        ],
      ),
    );
  }
}
