import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copia una imagen elegida por el usuario al directorio de portadas de la
/// app (`playlist_covers/`) y devuelve la ruta de destino.
///
/// Copiar (en vez de referenciar el archivo original) hace que la portada
/// sobreviva aunque el usuario mueva o borre el archivo original. Si la
/// fuente ya está en el destino (se eligió la propia portada), no copia.
Future<String> copyPlaylistCoverToAppDir(
  int playlistId,
  String sourcePath,
) async {
  final base = await getApplicationSupportDirectory();
  final coversDir = Directory(p.join(base.path, 'playlist_covers'));
  await coversDir.create(recursive: true);
  final ext = p.extension(sourcePath);
  final dest = p.join(coversDir.path, 'playlist_$playlistId$ext');
  if (!p.equals(sourcePath, dest)) {
    await File(sourcePath).copy(dest);
  }
  return dest;
}
