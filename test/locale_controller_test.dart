import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/services/settings_store.dart';
import 'package:scrup/ui/locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('arranca con el idioma inicial', () {
    final controller = LocaleController(const Locale('es'));
    expect(controller.locale.languageCode, 'es');
  });

  test('cambia el idioma, notifica y lo persiste', () async {
    final settings = SettingsStore();
    final controller = LocaleController(const Locale('es'));
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.setLocale(const Locale('en'), settings);
    expect(controller.locale.languageCode, 'en');
    expect(notified, 1);
    expect(await settings.loadLocale(), 'en');

    // Cambiar al mismo idioma no notifica ni vuelve a persistir.
    await controller.setLocale(const Locale('en'), settings);
    expect(notified, 1);
  });

  test('persiste el locale completo con región (pt_BR)', () async {
    final settings = SettingsStore();
    final controller = LocaleController(const Locale('es'));

    await controller.setLocale(const Locale('pt', 'BR'), settings);

    // Se guarda el BCP-47 completo, no solo el código de idioma.
    expect(await settings.loadLocale(), 'pt_BR');
    // Y el round-trip devuelve el mismo locale (comparación por == completo).
    expect(controller.locale, const Locale('pt', 'BR'));

    // El mismo locale con región distinta no se considera igual a `pt`.
    await controller.setLocale(const Locale('pt'), settings);
    expect(await settings.loadLocale(), 'pt');
  });

  group('parseStoredLocale', () {
    test('parsea códigos sin región', () {
      expect(parseStoredLocale('es'), const Locale('es'));
      expect(parseStoredLocale('en'), const Locale('en'));
    });

    test('parsea códigos con región (_ o -)', () {
      expect(parseStoredLocale('pt_BR'), const Locale('pt', 'BR'));
      expect(parseStoredLocale('pt-BR'), const Locale('pt', 'BR'));
    });
  });
}
