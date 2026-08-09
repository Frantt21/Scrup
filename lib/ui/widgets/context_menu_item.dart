import 'package:flutter/material.dart';

/// Item de menú contextual (clic derecho) con la estética de la app: icono
/// en el color de acento y tamaño contenido, con el label en el estilo del
/// menú. Compartido por todos los `showMenu` del app para que se vean
/// iguales.
///
/// Nota: los menús empujados al Overlay del Navigator NO heredan los `Theme`
/// locales (p. ej. el del detalle de playlist), así que el icono usa el
/// acento de la app (lila / el de la canción) en todos lados — consistente
/// por diseño.
class ContextMenuItem extends PopupMenuItem<String> {
  ContextMenuItem({
    super.key,
    required super.value,
    required IconData icon,
    required String label,
  }) : super(
         child: _MenuItemBody(icon: icon, label: label),
       );
}

/// Contenido del item: icono con el acento de la app + label.
class _MenuItemBody extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuItemBody({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
