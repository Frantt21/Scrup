import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/queue_shuffle.dart';
import 'package:scrup/core/track.dart';

void main() {
  // Random con semilla fija: los tests solo verifican invariantes
  // (permutación, pista conservada), no el orden exacto.
  final seed = 42;

  Track track(String id, [String title = '']) =>
      Track(id: id, title: title, artist: 'Artista');

  group('shuffleKeepingCurrent', () {
    test('baraja la cola y devuelve el nuevo índice de la pista actual', () {
      final queue = [
        track('a'),
        track('b'),
        track('c'),
        track('d'),
        track('e'),
      ];
      final originalIds = queue.map((t) => t.id).toList()..sort();
      final current = queue[2];

      final idx = shuffleKeepingCurrent(queue, current, Random(seed));

      expect(idx, inInclusiveRange(0, queue.length - 1));
      expect(queue[idx], same(current), reason: 'la pista actual no cambia');
      expect(
        queue.map((t) => t.id).toList()..sort(),
        originalIds,
        reason: 'la cola es una permutación de la original',
      );
    });

    test('con duplicados conserva la instancia exacta que suena', () {
      // Dos pistas con el MISMO id pero instancias distintas.
      final queue = [track('dup'), track('b'), track('dup'), track('c')];
      final current = queue[2]; // la segunda instancia de 'dup'

      final idx = shuffleKeepingCurrent(queue, current, Random(seed));

      expect(idx, isNot(-1));
      expect(
        identical(queue[idx], current),
        isTrue,
        reason:
            'por id se encontraría cualquiera de las dos duplicadas; '
            'por identidad, la exacta que suena',
      );
    });

    test('sin pista actual devuelve -1', () {
      final queue = [track('a'), track('b'), track('c')];
      final idx = shuffleKeepingCurrent(queue, null, Random(seed));
      expect(idx, -1);
    });

    test('con ≤1 pistas no baraja nada', () {
      final one = [track('a')];
      final current = one[0];
      expect(shuffleKeepingCurrent(one, current, Random(seed)), 0);
      expect(one[0].id, 'a');

      final empty = <Track>[];
      expect(shuffleKeepingCurrent(empty, null, Random(seed)), -1);
    });
  });

  group('promoteThenShuffle', () {
    test('la pista elegida queda primera y el resto se baraja detrás', () {
      final queue = [
        track('a'),
        track('b'),
        track('c'),
        track('d'),
        track('e'),
      ];
      final originalIds = queue.map((t) => t.id).toList()..sort();

      final idx = promoteThenShuffle(queue, 3, Random(seed));

      expect(idx, 0);
      expect(queue[0].id, 'd', reason: 'la elegida queda primera');
      expect(queue.length, originalIds.length);
      expect(
        queue.map((t) => t.id).toList()..sort(),
        originalIds,
        reason: 'la cola es una permutación de la original',
      );
    });

    test('con ≤1 pistas devuelve el índice original sin tocar la lista', () {
      final one = [track('a')];
      expect(promoteThenShuffle(one, 0, Random(seed)), 0);
      expect(one[0].id, 'a');

      final empty = <Track>[];
      expect(promoteThenShuffle(empty, 0, Random(seed)), 0);
      expect(empty, isEmpty);
    });

    test('recorta índices fuera de rango', () {
      final queue = [track('a'), track('b'), track('c')];
      final idx = promoteThenShuffle(queue, 99, Random(seed));
      expect(idx, 0);
      // Se promovió la última pista (índice recortado a length-1).
      expect(queue.first.id, 'c');

      final negative = [track('a'), track('b'), track('c')];
      final negIdx = promoteThenShuffle(negative, -5, Random(seed));
      expect(negIdx, 0);
      expect(negative.first.id, 'a');
    });
  });

  group('restoreQueueOrder', () {
    test('restaura el orden original sin tocar el contenido', () {
      // Cola barajada actual y el orden guardado antes de barajar.
      final original = [track('a'), track('b'), track('c'), track('d')];
      final shuffled = [original[2], original[0], original[3], original[1]];
      final current = shuffled[0]; // original[2]

      final (restored, index) = restoreQueueOrder(shuffled, original, current);

      expect(restored.map((t) => t.id).toList(), ['a', 'b', 'c', 'd']);
      expect(index, 2, reason: 'la pista actual vuelve a su posición original');
      expect(restored[index], same(current));
    });

    test('conserva al final las pistas añadidas con shuffle activo', () {
      // La radio añadió dos pistas mientras shuffle estaba activo.
      final original = [track('a'), track('b'), track('c')];
      final shuffled = [
        original[2],
        track('r1'),
        original[0],
        track('r2'),
        original[1],
      ];
      final current = shuffled[1]; // la pista de radio r1

      final (restored, index) = restoreQueueOrder(shuffled, original, current);

      // Original primero; r1 y r2 al final en su orden relativo.
      expect(restored.map((t) => t.id).toList(), ['a', 'b', 'c', 'r1', 'r2']);
      expect(index, 3, reason: 'la pista de radio actual se conserva sonando');
      expect(restored[index], same(current));
    });

    test(
      'sin pista actual devuelve -1 y no modifica las listas de entrada',
      () {
        final original = [track('a'), track('b')];
        final shuffled = [original[1], original[0]];
        final before = List.of(shuffled);

        final (restored, index) = restoreQueueOrder(shuffled, original, null);

        expect(index, -1);
        expect(restored.map((t) => t.id).toList(), ['a', 'b']);
        expect(
          shuffled.map((t) => t.id).toList(),
          before.map((t) => t.id).toList(),
          reason: 'la función es pura: no muta la cola de entrada',
        );
      },
    );

    test('con duplicados por id conserva la instancia exacta que suena', () {
      final original = [track('dup'), track('b'), track('c')];
      // Segunda instancia de 'dup' añadida por radio (mismo id, otro objeto).
      final dup2 = track('dup');
      final shuffled = [original[0], dup2, original[1], original[2]];
      final current = dup2;

      final (restored, index) = restoreQueueOrder(shuffled, original, current);

      // dup2 no está en el orden original → se conserva al final.
      expect(restored.map((t) => t.id).toList(), ['dup', 'b', 'c', 'dup']);
      expect(
        identical(restored[index], dup2),
        isTrue,
        reason:
            'por id se encontraría la primera duplicada; por identidad, '
            'la exacta que suena',
      );
    });
  });
}
