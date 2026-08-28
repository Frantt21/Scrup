import 'dart:math';

/// Pure shuffle utilities for queue management.
/// Randomness lives in queue order, not the player.

int shuffleKeepingCurrent<T>(List<T> queue, T? current, Random random) {
  if (queue.length > 1) queue.shuffle(random);
  if (current == null) return -1;
  return queue.indexWhere((t) => identical(t, current));
}

// Promotes track at startIndex to front, then shuffles the rest.
int promoteThenShuffle<T>(List<T> queue, int startIndex, Random random) {
  if (queue.isEmpty) return startIndex;
  final playIndex = startIndex.clamp(0, queue.length - 1);
  if (queue.length <= 1) return playIndex;
  final start = queue.removeAt(playIndex);
  queue.shuffle(random);
  queue.insert(0, start);
  return 0;
}

// Restores queue order when shuffle is turned off (Spotify-style).
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
