import 'package:flutter/widgets.dart';

/// Tope máximo de overscroll (estirado) en píxeles lógicos, para los heroes
/// que comparten estilo (detalle de playlist, de artista y de álbum).
const double kMaxHeroOverscroll = 96.0;

/// [BouncingScrollPhysics] con un TOPE en el overscroll (estirado).
///
/// El efecto de estirado del hero ([SliverAppBar.stretch]) y su difuminado
/// ([StretchMode.blurBackground]) se alimentan del overscroll. Con
/// [BouncingScrollPhysics] ese overscroll NO tiene límite: cuanto más arrastras
/// hacia abajo, más se estira el hero y mayor es el sigma del difuminado, lo
/// que acaba degradando el render. Esta física acota el overscroll a
/// [maxOverscroll] en ambos extremos, de modo que el efecto se ve pero deja de
/// crecer.
class CappedBouncingScrollPhysics extends BouncingScrollPhysics {
  /// Máximo de overscroll permitido (en px lógicos) más allá de cada extremo.
  final double maxOverscroll;

  const CappedBouncingScrollPhysics({
    this.maxOverscroll = kMaxHeroOverscroll,
    super.parent,
  });

  @override
  CappedBouncingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return CappedBouncingScrollPhysics(
      maxOverscroll: maxOverscroll,
      parent: buildParent(ancestor),
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final double applied = super.applyPhysicsToUserOffset(position, offset);
    // Píxeles resultantes si se aplicara el delta ya con la fricción normal.
    final double candidate = position.pixels - applied;

    // Acota el resultado a [min - tope, max + tope]. Dentro del rango el clamp
    // es un no-op (candidate ya está entre min y max).
    final double lower = position.minScrollExtent - maxOverscroll;
    final double upper = position.maxScrollExtent + maxOverscroll;
    final double clamped = candidate < lower
        ? lower
        : (!upper.isFinite || candidate <= upper)
        ? candidate
        : upper;

    return position.pixels - clamped;
  }
}
