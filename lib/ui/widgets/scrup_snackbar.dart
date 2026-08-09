import 'package:flutter/material.dart';

import 'player_bar.dart' show kPlayerOverlayInset;

/// Muestra un SnackBar flotante por encima del player glass inferior (que
/// ocupa ~[kPlayerOverlayInset] px al fondo), para no taparlo.
void showScrupSnackBar(ScaffoldMessengerState messenger, String message) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(16, 0, 16, kPlayerOverlayInset + 16),
    ),
  );
}
