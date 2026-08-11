import 'dart:math';

/// Utilidades PURAS de barajado de cola de reproducción, extraídas de
/// `PlayerService` para poder testear la lógica de shuffle sin depender de
/// un reproductor media_kit.
///
/// Modelo del app: la aleatoriedad vive en el ORDEN de la cola, no en el
/// reproductor. El player sigue la cola secuencialmente; la cola se baraja
/// al activar shuffle o al reproducir con shuffle activo.

/// Baraja [queue] IN PLACE y devuelve el nuevo índice de [current] dentro de
/// la cola barajada (o -1 si [current] es null o ya no está en la lista).
///
/// La búsqueda es POR IDENTIDAD de instancia ([identical]), no por id: si la
/// cola tiene pistas duplicadas (mismo id), se conserva la instancia exacta
/// que está sonando. Con ≤1 pistas no baraja nada.
int shuffleKeepingCurrent<T>(List<T> queue, T? current, Random random) {
  if (queue.length > 1) queue.shuffle(random);
  if (current == null) return -1;
  return queue.indexWhere((t) => identical(t, current));
}

/// Prepara la cola para reproducir con shuffle: la pista en [startIndex]
/// queda PRIMERA y el resto se baraja detrás (in place).
///
/// Devuelve el índice a reproducir: `0` cuando se barajó, o [startIndex]
/// (recortado al rango válido) si la cola tiene ≤1 pistas.
int promoteThenShuffle<T>(List<T> queue, int startIndex, Random random) {
  if (queue.isEmpty) return startIndex;
  final playIndex = startIndex.clamp(0, queue.length - 1);
  if (queue.length <= 1) return playIndex;
  final start = queue.removeAt(playIndex);
  queue.shuffle(random);
  queue.insert(0, start);
  return 0;
}

/// Calcula la cola restaurada al DESACTIVAR shuffle (como Spotify): el orden
/// original [original] (guardado antes de barajar) primero, y las pistas de
/// [queue] que NO estaban en él —añadidas con shuffle activo, p. ej. radio—
/// después, conservando su orden relativo actual.
///
/// Devuelve la cola restaurada y el índice de [current] dentro de ella por
/// IDENTIDAD de instancia (o -1 si es null o ya no está). No modifica
/// ninguna de las listas de entrada.
(List<T>, int) restoreQueueOrder<T>(
  List<T> queue,
  List<T> original,
  T? current,
) {
  final restored = <T>[...original];
  for (final t in queue) {
    if (!original.any((o) => identical(o, t))) {
      restored.add(t);
    }
  }
  final index = current == null
      ? -1
      : restored.indexWhere((t) => identical(t, current));
  return (restored, index);
}
