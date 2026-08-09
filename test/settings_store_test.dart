import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('guarda y restaura el volumen', () async {
    final store = SettingsStore();
    expect(await store.loadVolume(), isNull);

    await store.saveVolume(0.42);
    expect(await store.loadVolume(), 0.42);

    await store.saveVolume(0.0); // mute
    expect(await store.loadVolume(), 0.0);
  });

  test('guarda y restaura la última pista', () async {
    final store = SettingsStore();
    expect(await store.loadLastTrackId(), isNull);

    await store.saveLastTrackId('v123');
    expect(await store.loadLastTrackId(), 'v123');

    // Sobrescribir con otra pista
    await store.saveLastTrackId('v456');
    expect(await store.loadLastTrackId(), 'v456');
  });
}
