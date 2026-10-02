import 'package:flutter/material.dart';

/// Un segmento de un [SegmentedPills]. El label y/o el icono se muestran
/// centrados; el `badge` opcional aparece como texto secundario atenuado
/// (p. ej. el nº de resultados o el espacio usado).
class SegmentedPill<T> {
  final T value;
  final String? label;
  final IconData? icon;
  final String? badge;
  final String? tooltip;

  const SegmentedPill({
    required this.value,
    this.label,
    this.icon,
    this.badge,
    this.tooltip,
  });
}

/// Grupo de píldoras segmentadas con la MISMA receta que los tabs de la
/// biblioteca (desktop): contenedor único `radius 10` con
/// `surfaceContainerHighest α 0.35`, segmento activo en `primary α 0.25` con
/// texto/icono `primary` y peso 600, inactivo `onSurfaceVariant` peso 500.
///
/// [expand] reparte los segmentos a partes iguales (como los tabs de la
/// biblioteca en el sidebar); con `false` el grupo toma solo el ancho que
/// necesita. [scrollable] añade scroll horizontal cuando los segmentos no
/// caben (p. ej. muchas playlists en el diálogo de descargas). [dense] usa
/// padding y tipografía compactos.
class SegmentedPills<T> extends StatelessWidget {
  final List<SegmentedPill<T>> items;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;
  final bool dense;
  final bool scrollable;

  const SegmentedPills({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.dense = false,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final item in items)
          if (expand)
            Expanded(child: _segment(context, item))
          else
            _segment(context, item),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: scrollable
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: row,
            )
          : row,
    );
  }

  Widget _segment(BuildContext context, SegmentedPill<T> item) {
    final theme = Theme.of(context);
    final active = item.value == selected;
    final fg = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    final baseStyle = dense
        ? theme.textTheme.labelMedium
        : theme.textTheme.labelLarge;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (item.icon != null) Icon(item.icon, size: dense ? 17 : 18, color: fg),
        if (item.icon != null && item.label != null) const SizedBox(width: 6),
        if (item.label != null)
          Flexible(
            child: Text(
              item.label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: baseStyle?.copyWith(
                fontSize: dense ? 11.5 : null,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        if (item.badge != null) ...[
          const SizedBox(width: 6),
          Text(
            item.badge!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg.withValues(alpha: 0.75),
            ),
          ),
        ],
      ],
    );

    final segment = Material(
      color: active
          ? theme.colorScheme.primary.withValues(alpha: 0.25)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(item.value),
        mouseCursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 4 : 12,
            vertical: 6,
          ),
          child: Center(child: content),
        ),
      ),
    );

    if (item.tooltip == null) return segment;
    return Tooltip(
      message: item.tooltip!,
      waitDuration: const Duration(milliseconds: 400),
      child: segment,
    );
  }
}
