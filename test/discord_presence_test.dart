import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/track.dart';
import 'package:scrup/services/discord/discord_presence_service.dart';

void main() {
  Track track({
    String id = 'abc123',
    String title = 'Una Vez',
    String artist = 'Artista',
    String? album,
    Duration? duration,
    String? thumbnailUrl,
  }) {
    return Track(
      id: id,
      title: title,
      artist: artist,
      duration: duration,
      thumbnailUrl: thumbnailUrl,
      album: album,
    );
  }

  group('DiscordPresenceService.buildActivity', () {
    test(
      'tipo LISTENING siempre, sin url (STREAMING es rechazado por IPC)',
      () {
        final a = DiscordPresenceService.buildActivity(
          track: track(),
          trackStartTime: DateTime.now().subtract(const Duration(seconds: 30)),
          total: const Duration(minutes: 4),
        )!;
        expect(a['type'], 2);
        expect(a.containsKey('url'), isFalse);
      },
    );

    test('details es el título, state el artista y name el título', () {
      final a = DiscordPresenceService.buildActivity(
        track: track(album: 'El Disco'),
        trackStartTime: DateTime.now(),
      )!;
      expect(a['details'], 'Una Vez');
      expect(a['state'], 'Artista');
      // 'name' sobrescribe el header "Listening to <App>" de Discord.
      expect(a['name'], 'Una Vez');
    });

    test(
      'barra de progreso: end - start = duración total y end en el futuro',
      () {
        final pos = const Duration(minutes: 1);
        final total = const Duration(minutes: 4); // quedan 3 min
        final a = DiscordPresenceService.buildActivity(
          track: track(duration: total),
          trackStartTime: DateTime.now().subtract(pos),
          total: total,
        )!;
        final ts = a['timestamps'] as Map<String, dynamic>;
        final start = ts['start'] as int;
        final end = ts['end'] as int;
        // start retrocede lo reproducido y end apunta al fin: entre ambos hay
        // EXACTAMENTE la duración total de la pista.
        expect(end - start, total.inSeconds);
        // end debe estar en el futuro inmediato (~now + restante).
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        expect((end - nowSec).abs(), lessThanOrEqualTo(180));
      },
    );

    test('sin duración conocida no hay end (cronómetro simple)', () {
      final a = DiscordPresenceService.buildActivity(
        track: track(duration: null),
        trackStartTime: DateTime.now().subtract(const Duration(seconds: 10)),
      )!;
      final ts = a['timestamps'] as Map<String, dynamic>;
      expect(ts.containsKey('start'), isTrue);
      expect(ts.containsKey('end'), isFalse);
    });

    test('portada como large_image y álbum en large_text', () {
      final a = DiscordPresenceService.buildActivity(
        track: track(
          album: 'El Disco',
          thumbnailUrl: 'https://i.ytimg.com/x.jpg',
        ),
        trackStartTime: DateTime.now(),
      )!;
      final assets = a['assets'] as Map<String, dynamic>;
      expect(assets['large_image'], 'https://i.ytimg.com/x.jpg');
      expect(assets['large_text'], 'El Disco');
    });

    test('sin portada no hay large_image (solo small_image)', () {
      final a = DiscordPresenceService.buildActivity(
        track: track(thumbnailUrl: null),
        trackStartTime: DateTime.now(),
      )!;
      final assets = a['assets'] as Map<String, dynamic>;
      expect(assets.containsKey('large_image'), isFalse);
      expect(assets['small_image'], 'scrup_icon');
    });
  });
}