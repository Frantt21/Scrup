import 'package:flutter/material.dart';

/// Logo del app ([assets/app-logo.png]) para la barra superior. Si la imagen
/// no está disponible se degrada a un icono de ecualizador con el acento.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/app-logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Scrup',
      errorBuilder: (_, _, _) => Icon(
        Icons.graphic_eq,
        size: size,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
