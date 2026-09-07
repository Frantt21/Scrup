import 'package:flutter/material.dart';


/// Context menu item (right-click) with the app's aesthetic: icon in the accent color and contained size, with the label in the menu style. Shared by all `showMenu` calls in the app so they look the same.
///
/// [color] lets you force the icon color (e.g. the playlist's artwork): without it, the app accent is used. It must be passed explicitly because menus pushed to the Navigator Overlay do NOT inherit local `Theme`s (e.g. the playlist detail's).
class ContextMenuItem extends PopupMenuItem<String> {
  ContextMenuItem({
    super.key,
    required String value,
    required IconData icon,
    required String label,
    this.color,
  }) : super(
         value: value,
         child: _MenuItemBody(icon: icon, label: label, color: color),
       );

  final Color? color;
}

/// Contenido del item: icono con el acento (o el color forzado) + label.
class _MenuItemBody extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MenuItemBody({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: color ?? theme.colorScheme.primary),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
