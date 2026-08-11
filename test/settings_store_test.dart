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

  test('guarda y restaura el modo del sidebar (lista/cuadrícula)', () async {
    final store = SettingsStore();
    expect(await store.loadSidebarGridMode(), isNull);

    await store.saveSidebarGridMode(true); // cuadrícula
    expect(await store.loadSidebarGridMode(), isTrue);

    await store.saveSidebarGridMode(false); // lista
    expect(await store.loadSidebarGridMode(), isFalse);
  });

  test('guarda y restaura el idioma', () async {
    final store = SettingsStore();
    expect(await store.loadLocale(), isNull);

    await store.saveLocale('en');
    expect(await store.loadLocale(), 'en');

    await store.saveLocale('es');
    expect(await store.loadLocale(), 'es');
  });

  test('guarda y restaura el modo shuffle', () async {
    final store = SettingsStore();
    expect(await store.loadShuffleEnabled(), isNull);

    await store.saveShuffleEnabled(true);
    expect(await store.loadShuffleEnabled(), isTrue);

    await store.saveShuffleEnabled(false);
    expect(await store.loadShuffleEnabled(), isFalse);
  });

  test('guarda y restaura el modo de repetición', () async {
    final store = SettingsStore();
    expect(await store.loadRepeatMode(), isNull);

    await store.saveRepeatMode('all');
    expect(await store.loadRepeatMode(), 'all');

    await store.saveRepeatMode('one');
    expect(await store.loadRepeatMode(), 'one');

    await store.saveRepeatMode('off');
    expect(await store.loadRepeatMode(), 'off');
  });

  test('guarda y restaura la cola (orden, índice y playlist activa)', () async {
    final store = SettingsStore();
    expect(await store.loadQueue(), isNull);
    expect(await store.loadOriginalQueue(), isNull);
    expect(await store.loadQueueIndex(), isNull);
    expect(await store.loadActivePlaylistId(), isNull);

    await store.saveQueue(['v1', 'v2', 'v3']);
    await store.saveOriginalQueue(['v1', 'v2', 'v3']);
    await store.saveQueueIndex(1);
    await store.saveActivePlaylistId(7);
    expect(await store.loadQueue(), ['v1', 'v2', 'v3']);
    expect(await store.loadOriginalQueue(), ['v1', 'v2', 'v3']);
    expect(await store.loadQueueIndex(), 1);
    expect(await store.loadActivePlaylistId(), 7);

    // Limpiar las claves opcionales pasando null
    await store.saveOriginalQueue(null);
    await store.saveActivePlaylistId(null);
    expect(await store.loadOriginalQueue(), isNull);
    expect(await store.loadActivePlaylistId(), isNull);

    // Sobrescribir la cola y vaciarla
    await store.saveQueue(['v9']);
    expect(await store.loadQueue(), ['v9']);
    await store.saveQueue([]);
    expect(await store.loadQueue(), isEmpty);
  });
}
