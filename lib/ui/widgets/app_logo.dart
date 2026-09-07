import 'package:flutter/material.dart';

/// App logo ([assets/app-logo.png]) for the top bar. If the image is not available, it falls back to an equalizer icon with the accent.
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
        Icons.graphic_eq_rounded,
        size: size,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
