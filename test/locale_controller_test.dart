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
}
