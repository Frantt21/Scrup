import 'dart:async';
import 'package:flutter/material.dart';

/// Toast type: changes the icon and the tint of the border/accent.
enum ScrupToastKind {
  /// Neutral confirmation (e.g. \"Added to playlist\").
  info,

  /// Action completed successfully.
  success,

  /// Something failed (playback, save, cache…).
  error,
}

/// Shows a floating notification at the TOP of the app (instead of Flutter's SnackBar, which appears at the bottom with the default style).
///
/// It is a context-free singleton: call sites can fire toasts from anywhere (listeners, helpers, views). The host ([ScrupToastHost]) is mounted in the AppShell and handles rendering them.
void showScrupToast(
  String message, {
  ScrupToastKind kind = ScrupToastKind.info,
  Duration duration = const Duration(seconds: 4),
}) {
  ScrupToastController.instance.show(message, kind: kind, duration: duration);
}

/// Global toast controller: keeps the active stack (max [maxVisible]), auto-closes each one with a timer, and notifies the host to repaint.
class ScrupToastController extends ChangeNotifier {
  ScrupToastController._();

  static final ScrupToastController instance = ScrupToastController._();

  /// Maximum simultaneous notifications to the view: the oldest ones are discarded when a new one arrives (avoids stacking a wall of toasts).
  static const int maxVisible = 3;

  final List<ActiveToast> _toasts = [];
  int _nextId = 0;

  List<ActiveToast> get toasts => List.unmodifiable(_toasts);

  void show(
    String message, {
    ScrupToastKind kind = ScrupToastKind.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    final toast = ActiveToast(id: _nextId++, message: message, kind: kind);
    _toasts.add(toast);
    while (_toasts.length > maxVisible) {
      final removed = _toasts.removeAt(0);
      removed.timer?.cancel();
    }
    toast.timer = Timer(duration, () => dismiss(toast.id));
    notifyListeners();
  }

  void dismiss(int id) {
    final index = _toasts.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _toasts[index].timer?.cancel();
    _toasts.removeAt(index);
    notifyListeners();
  }

  void dismissAll() {
    for (final t in _toasts) {
      t.timer?.cancel();
    }
    _toasts.clear();
    notifyListeners();
  }
}

/// Toast activo (estado interno del controlador).
class ActiveToast {
  ActiveToast({required this.id, required this.message, required this.kind});

  final int id;
  final String message;
  final ScrupToastKind kind;
  Timer? timer;
}

/// Host de las notificaciones: columna centrada en la PARTE SUPERIOR del
/// app, justo bajo la barra superior (CustomTitleBar/_SimpleTopBar). Se monta
/// en el `builder` del MaterialApp (sobre el navigator raíz) para que los
/// toasts floten por encima de los diálogos/modales; cuando no hay toasts no
/// ocupa nada ni bloquea clics.
class ScrupToastHost extends StatelessWidget {
  const ScrupToastHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ScrupToastController.instance,
      builder: (context, _) {
        final toasts = ScrupToastController.instance.toasts;
        if (toasts.isEmpty) return const SizedBox.shrink();
        // top = 40 (barra superior del app) + 12 (margen): las notificaciones
        // quedan justo bajo la CustomTitleBar/_SimpleTopBar.
        return Positioned(
          top: 52,
          left: 0,
          right: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final toast in toasts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ToastCard(key: ValueKey(toast.id), toast: toast),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Tarjeta de notificación tipo glass: entra con slide+fade desde arriba,
/// se cierra al hacer clic (o sola con el timer). Icono según el tipo, con
/// el tinte del acento (o error) y borde sutil como el resto de la app.
class ToastCard extends StatelessWidget {
  const ToastCard({super.key, required this.toast});

  final ActiveToast toast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = toast.kind;
    final accent = kind == ScrupToastKind.error
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final icon = switch (kind) {
      ScrupToastKind.info => Icons.info_outline_rounded,
      ScrupToastKind.success => Icons.check_circle_outline_rounded,
      ScrupToastKind.error => Icons.error_outline_rounded,
    };

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, -24 * (1 - t)),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: () => ScrupToastController.instance.dismiss(toast.id),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              // Plano: sin degradado ni borde, un único color sólido (el
              // acento queda solo en el icono).
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.95,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: accent),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        toast.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
