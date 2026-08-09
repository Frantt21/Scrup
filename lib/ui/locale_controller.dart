import 'package:flutter/widgets.dart';

import '../services/settings_store.dart';

/// Mantiene el idioma activo de la interfaz y notifica a la app cuando cambia
/// (el MaterialApp se reconstruye con el nuevo `locale`). Los cambios se
/// persisten en [SettingsStore] para restaurarse entre sesiones.
class LocaleController extends ChangeNotifier {
  LocaleController(this._locale);

  Locale _locale;

  /// Idioma activo (por defecto el español, como antes de la i18n).
  Locale get locale => _locale;

  /// Cambia el idioma, notifica a la UI y lo persiste. Si es el mismo que el
  /// actual no hace nada.
  Future<void> setLocale(Locale locale, SettingsStore settings) async {
    if (locale.languageCode == _locale.languageCode) return;
    _locale = locale;
    notifyListeners();
    try {
      await settings.saveLocale(locale.languageCode);
    } catch (_) {
      // La preferencia nunca debe romper el cambio de idioma.
    }
  }
}
