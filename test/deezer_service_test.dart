import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scrup/core/track.dart';
import 'package:scrup/services/deezer_service.dart';

/// Construye una respuesta de Deezer en memoria (bytes UTF-8 para que los
/// acentos no se corrompan con el latin1 por defecto de http.Response).
http.Response _deezerResponse(List<Map<String, dynamic>> data) {
  return http.Response.bytes(utf8.encode(jsonEncode({'data': data})), 200);
}

Map<String, dynamic> _dzTrack({
  String title = 'One More Time',
  String artist = 'Daft Punk',
  String album = 'Discovery',
  String md5 = 'abc123',
}) {
  return {
    'id': 3135553,
    'title': title,
    'duration': 320,
    'md5_image': md5,
    'artist': {'id': 27, 'name': artist},
    'album': {'id': 302127, 'title': album},
  };
}

void main() {
  group('DeezerService.enrich', () {
    test(
      'enriquece con título, artista, álbum y portada en alta resolución',
      () async {
        final client = MockClient((_) async => _deezerResponse([_dzTrack()]));
        final service = DeezerService(client: client);

        final original = Track(
          id: 'yt1',
          title: 'One More Time (Official Video)',
          artist: 'Daft Punk',
        );
        final enriched = service.apply(
          original,
          await service.enrich(original),
        );

        expect(enriched, isNotNull);
        expect(enriched!.id, 'yt1'); // se conserva el id de YouTube
        expect(enriched.title, 'One More Time');
        expect(enriched.artist, 'Daft Punk');
        expect(enriched.album, 'Discovery');
        expect(
          enriched.thumbnailUrl,
          'https://e-cdns-images.dzcdn.net/images/cover/abc123/'
          '500x500-000000-80-0-0.jpg',
        );
        expect(enriched.duration, original.duration);
      },
    );

    test('elige el mejor match entre varios resultados', () async {
      final client = MockClient(
        (_) async => _deezerResponse([
          _dzTrack(title: 'One More Time (Daft Punk Remix)', artist: 'Otro'),
          _dzTrack(), // el exacto, segundo en la lista
        ]),
      );
      final service = DeezerService(client: client);

      final original = Track(
        id: 'yt2',
        title: 'One More Time',
        artist: 'Daft Punk',
      );
      final enriched = service.apply(original, await service.enrich(original));

      expect(enriched, isNotNull);
      expect(enriched!.title, 'One More Time');
      expect(enriched.artist, 'Daft Punk');
      expect(enriched.album, 'Discovery');
    });

    test('rechaza una canción distinta del mismo artista', () async {
      final client = MockClient(
        (_) async => _deezerResponse([
          _dzTrack(title: 'Something Completely Different'),
        ]),
      );
      final service = DeezerService(client: client);

      final original = Track(
        id: 'yt3',
        title: 'One More Time',
        artist: 'Daft Punk',
      );
      final result = await service.enrich(original);

      expect(result, isNull);
    });

    test('rechaza cuando no hay ninguna coincidencia fiable', () async {
      final client = MockClient(
        (_) async => _deezerResponse([
          _dzTrack(title: 'Blinding Lights', artist: 'The Weeknd'),
        ]),
      );
      final service = DeezerService(client: client);

      final original = Track(
        id: 'yt4',
        title: 'Mi Canción Rara',
        artist: 'Artista Desconocido',
      );
      final result = await service.enrich(original);

      expect(result, isNull);
    });

    test('caché: la segunda llamada no repite la petición', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _deezerResponse([_dzTrack()]);
      });
      final service = DeezerService(client: client);

      final original = Track(
        id: 'yt5',
        title: 'One More Time',
        artist: 'Daft Punk',
      );
      final first = await service.enrich(original);
      final second = await service.enrich(original);

      expect(calls, 1);
      expect(first?.title, second?.title);
    });

    test('devuelve null si la API falla (error de red/HTTP)', () async {
      final client = MockClient((_) async => http.Response('error', 503));
      final service = DeezerService(client: client);

      final original = Track(id: 'yt6', title: 'Tema', artist: 'Artista');
      final result = await service.enrich(original);

      expect(result, isNull);
    });

    test('conserva el artista de YouTube si Deezer no trae artista', () async {
      final client = MockClient(
        (_) async => _deezerResponse([_dzTrack(artist: '')]),
      );
      final service = DeezerService(client: client);

      final original = Track(
        id: 'yt8',
        title: 'One More Time',
        artist: 'Daft Punk',
      );
      final enriched = service.apply(original, await service.enrich(original));

      expect(enriched, isNotNull);
      expect(enriched!.artist, 'Daft Punk');
      expect(enriched.title, 'One More Time');
    });

    test('normaliza diacríticos para comparar (Música vs Musica)', () async {
      final client = MockClient(
        (_) async => _deezerResponse([_dzTrack(title: 'Música')]),
      );
      final service = DeezerService(client: client);

      final original = Track(id: 'yt9', title: 'Musica', artist: 'Daft Punk');
      final result = await service.enrich(original);

      expect(result, isNotNull);
      expect(result!.title, 'Música');
    });

    test('enrichAll enriquece la lista y conserva las sin coincidencia',
        () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _deezerResponse([_dzTrack()]);
      });
      final service = DeezerService(client: client);

      final results = await service.enrichAll([
        Track(
          id: 'yt10',
          title: 'One More Time (Official Video)',
          artist: 'Daft Punk',
        ),
        Track(id: 'yt11', title: 'Mi Canción Rara', artist: 'Artista X'),
        Track(
          id: 'yt12',
          title: 'One More Time',
          artist: 'Daft Punk',
        ),
      ]);

      expect(results, hasLength(3));
      // Los que coinciden con Deezer quedan enriquecidos (mismo videoId).
      expect(results[0].id, 'yt10');
      expect(results[0].title, 'One More Time');
      expect(results[0].album, 'Discovery');
      // El que no coincide conserva la metadata original.
      expect(results[1].id, 'yt11');
      expect(results[1].title, 'Mi Canción Rara');
      expect(results[2].id, 'yt12');
      expect(results[2].title, 'One More Time');
      // Un request por video sin caché (cada track consulta su query).
      expect(calls, 3);
    });

    test('searchManual busca con datos escritos aunque el video ya esté '
        'cacheado como null', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _deezerResponse([_dzTrack()]);
      });
      final service = DeezerService(client: client);

      // El enriquecimiento automático de un video sin match cachea null.
      final original = Track(
        id: 'yt20',
        title: 'Título Raro',
        artist: 'Artista Desconocido',
      );
      expect(await service.enrich(original), isNull);
      expect(calls, 1);

      // La búsqueda manual con el título/artista corregidos SÍ consulta la
      // API (no repite el null cacheado) y devuelve la metadata.
      final result = await service.searchManual('One More Time', 'Daft Punk');
      expect(result, isNotNull);
      expect(result!.title, 'One More Time');
      expect(result.artist, 'Daft Punk');
      expect(calls, 2);
    });

    test('enrichAll con lista vacía no llama a la API', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return _deezerResponse([_dzTrack()]);
      });
      final service = DeezerService(client: client);

      final results = await service.enrichAll(const []);

      expect(results, isEmpty);
      expect(called, isFalse);
    });

    test('devuelve null si no hay artista ni título', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return _deezerResponse([_dzTrack()]);
      });
      final service = DeezerService(client: client);

      final original = Track(id: 'yt7', title: '   ', artist: '  ');
      final result = await service.enrich(original);

      expect(result, isNull);
      expect(called, isFalse);
    });
  });
}
