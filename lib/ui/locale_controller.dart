import 'package:flutter/widgets.dart';

import '../services/settings_store.dart';

/// Parsea un código de idioma guardado (BCP-47: `es`, `en`, `pt_BR`) a un
/// [Locale]. Soporta regiones separadas por `_` o `-` (`pt_BR` → `pt`+`BR`).
Locale parseStoredLocale(String code) {
  final parts = code.split(RegExp(r'[_-]'));
  if (parts.length >= 2 && parts[1].isNotEmpty) {
    return Locale(parts[0], parts[1]);
  }
  return Locale(parts[0]);
}

/// Mantiene el idioma activo de la interfaz y notifica a la app cuando cambia
/// (el MaterialApp se reconstruye con el nuevo `locale`). Los cambios se
/// persisten en [SettingsStore] para restaurarse entre sesiones.
class LocaleController extends ChangeNotifier {
  LocaleController(this._locale);

  Locale _locale;

  /// Idioma activo (por defecto el español, como antes de la i18n).
  Locale get locale => _locale;

  /// Cambia el idioma, notifica a la UI y lo persiste. Si es el mismo que el
  /// actual no hace nada. Se compara el locale COMPLETO (no solo el código de
  /// idioma): así `pt_BR` y `pt` son locales distintos.
  Future<void> setLocale(Locale locale, SettingsStore settings) async {
    if (locale == _locale) return;
    _locale = locale;
    notifyListeners();
    try {
      // Guardar el código BCP-47 completo (p. ej. `pt_BR`) para no perder la
      // región al restaurar la sesión.
      await settings.saveLocale(locale.toString());
    } catch (_) {
      // La preferencia nunca debe romper el cambio de idioma.
    }
  }
}
