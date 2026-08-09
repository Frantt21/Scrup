import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Barra de título personalizada: área de arrastre + botones de control
/// (minimizar, maximizar/restaurar, cerrar).
class CustomTitleBar extends StatefulWidget {
  final Widget? leading;
  final String? title;

  const CustomTitleBar({super.key, this.leading, this.title});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initState();
  }

  Future<void> _initState() async {
    final isMax = await windowManager.isMaximized();
    if (!mounted) return;
    setState(() => _maximized = isMax);
  }

  @override
  void onWindowMaximize() {
    if (!mounted) return;
    setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (!mounted) return;
    setState(() => _maximized = false);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _minimize() => windowManager.minimize();
  Future<void> _toggleMaximize() async {
    if (_maximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _close() => windowManager.close();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Container(
      height: 40,
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          const SizedBox(width: 8),
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 8),
          ],
          if (widget.title != null)
            // Ancho acotado + ellipsis: un título largo (p. ej. el nombre de
            // una playlist) no debe empujar los botones de ventana.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          // Área de arrastre ocupa el espacio restante
          Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          // Controles de ventana
          _WindowButton(
            icon: Icons.remove,
            tooltip: 'Minimizar',
            onPressed: _minimize,
            hoverColor: onSurface.withValues(alpha: 0.08),
          ),
          _WindowButton(
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            tooltip: _maximized ? 'Restaurar' : 'Maximizar',
            onPressed: _toggleMaximize,
            hoverColor: onSurface.withValues(alpha: 0.08),
          ),
          _WindowButton(
            icon: Icons.close,
            tooltip: 'Cerrar',
            onPressed: _close,
            hoverColor: const Color(0xFFE81123),
            isClose: true,
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color hoverColor;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.hoverColor,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClose = widget.isClose;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: InkWell(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: double.infinity,
            color: _hovered ? widget.hoverColor : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered && isClose
                  ? Colors.white
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
