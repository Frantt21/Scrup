import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copy an image chosen by the user to the app's cover directory (`playlist_covers/`) and return the destination path.
///
/// Copying (instead of referencing the original file) makes the cover survive even if the user moves or deletes the original file. If the source is already in the destination (the playlist's own cover was chosen), it does not copy.
Future<String> copyPlaylistCoverToAppDir(
  int playlistId,
  String sourcePath,
) async {
  final base = await getApplicationSupportDirectory();
  final coversDir = Directory(p.join(base.path, 'playlist_covers'));
  await coversDir.create(recursive: true);
  final ext = p.extension(sourcePath);
  // Versioned name: each cover change produces a NEW path. Flutter caches `Image.file` by path, so reusing `playlist_$id$ext` showed the old cover until the view was recreated (or the app restarted). With a different path, the ImageCache is invalidated and the UI refreshes immediately.
  final millis = DateTime.now().millisecondsSinceEpoch;
  final dest = p.join(coversDir.path, 'playlist_${playlistId}_$millis$ext');
  if (!p.equals(sourcePath, dest)) {
    await File(sourcePath).copy(dest);
  }
  return dest;
}

/// Copy an image chosen by the user to the app's track cover directory (`track_covers/`) and return the destination path.
///
/// Same as [copyPlaylistCoverToAppDir]: it is copied (not referenced) so the cover survives even if the original file is moved or deleted, and the name is derived from the track id so it is stable across sessions (the edited metadata persists in the DB with this local path).
Future<String> copyTrackCoverToAppDir(String trackId, String sourcePath) async {
  final base = await getApplicationSupportDirectory();
  final coversDir = Directory(p.join(base.path, 'track_covers'));
  await coversDir.create(recursive: true);
  final ext = p.extension(sourcePath);
  final dest = p.join(coversDir.path, 'track_$trackId$ext');
  if (!p.equals(sourcePath, dest)) {
    await File(sourcePath).copy(dest);
  }
  return dest;
}
