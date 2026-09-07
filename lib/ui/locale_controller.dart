import 'package:flutter/widgets.dart';

import '../services/settings_store.dart';

/// Parse a stored language code (BCP-47: `es`, `en`, `pt_BR`) into a [Locale]. It supports regions separated by `_` or `-` (`pt_BR` -> `pt`+`BR`).
Locale parseStoredLocale(String code) {
  final parts = code.split(RegExp(r'[_-]'));
  if (parts.length >= 2 && parts[1].isNotEmpty) {
    return Locale(parts[0], parts[1]);
  }
  return Locale(parts[0]);
}

/// Keeps the active interface language and notifies the app when it changes (the MaterialApp is rebuilt with the new `locale`). Changes are persisted in [SettingsStore] to be restored between sessions.
class LocaleController extends ChangeNotifier {
  LocaleController(this._locale);

  Locale _locale;

  /// Active language (by default Spanish, as before i18n).
  Locale get locale => _locale;

  /// Change the language, notify the UI, and persist it. If it is the same as the current one, do nothing. The FULL locale is compared (not just the language code): this way `pt_BR` and `pt` are distinct locales.
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
