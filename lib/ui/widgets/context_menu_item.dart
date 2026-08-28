import 'package:flutter/material.dart';


/// Item de menú contextual (clic derecho) con la estética de la app: icono
/// en el color de acento y tamaño contenido, con el label en el estilo del
/// menú. Compartido por todos los `showMenu` del app para que se vean
/// iguales.
///
/// [color] permite forzar el color del icono (p. ej. el del artwork de la
/// playlist): sin él, se usa el acento de la app. Es necesario pasarlo
/// explícitamente porque los menús empujados al Overlay del Navigator NO
/// heredan los `Theme` locales (p. ej. el del detalle de playlist).
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
