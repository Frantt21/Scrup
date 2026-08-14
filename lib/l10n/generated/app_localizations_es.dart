// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => 'Configuración';

  @override
  String get backToPlaylists => 'Volver a playlists';

  @override
  String playbackErrorWithDetails(String details) {
    return 'Error de reproducción: $details';
  }

  @override
  String get searchHint => 'Buscar canciones en YouTube…';

  @override
  String get recentTitle => 'Recientes';

  @override
  String get addToPlaylist => 'Añadir a playlist';

  @override
  String get recentEmptyTitle => 'Aún no has reproducido nada';

  @override
  String get recentEmptyHint => 'Usa la búsqueda de arriba para empezar';

  @override
  String get backToHome => 'Volver al inicio';

  @override
  String get searchTitle => 'Buscar';

  @override
  String get searchStartHint => 'Busca una canción para empezar a reproducirla';

  @override
  String get searchNoResults => 'Sin resultados. Prueba otra búsqueda.';

  @override
  String get cantCreatePlaylist => 'No se pudo crear la playlist';

  @override
  String playlistCreated(String name) {
    return 'Playlist \"$name\" creada';
  }

  @override
  String get deletePlaylistTitle => 'Eliminar playlist';

  @override
  String confirmDeletePlaylist(String name) {
    return '¿Eliminar \"$name\"?';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Eliminar';

  @override
  String get playlistDeleted => 'Playlist eliminada';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get listViewTooltip => 'Vista de lista';

  @override
  String get gridViewTooltip => 'Vista de cuadrícula';

  @override
  String get noPlaylists => 'Aún no tienes playlists';

  @override
  String get createOneHere => 'Crea una desde aquí';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count canciones',
      one: '1 canción',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => 'Nueva playlist';

  @override
  String get newPlaylistHint => 'Crea una nueva';

  @override
  String get playlistName => 'Nombre';

  @override
  String get playlistNameHint => 'Mi playlist';

  @override
  String get descriptionOptional => 'Descripción (opcional)';

  @override
  String get descriptionHint => '¿De qué trata esta playlist?';

  @override
  String get description => 'Descripción';

  @override
  String get noCover => 'Sin portada';

  @override
  String get chooseImage => 'Elegir imagen';

  @override
  String get changeImage => 'Cambiar';

  @override
  String get removeImage => 'Quitar imagen';

  @override
  String get images => 'Imágenes';

  @override
  String get create => 'Crear';

  @override
  String get play => 'Reproducir';

  @override
  String get playShuffled => 'Reproducir en aleatorio';

  @override
  String get emptyPlaylist => 'Playlist vacía';

  @override
  String get emptyPlaylistHint => 'Añade canciones desde la búsqueda';

  @override
  String get removeFromPlaylist => 'Quitar de la playlist';

  @override
  String get editPlaylist => 'Editar playlist';

  @override
  String get edit => 'Editar';

  @override
  String get playlistUpdated => 'Playlist actualizada';

  @override
  String get cantSaveChanges => 'No se pudo guardar los cambios';

  @override
  String get lessThanOneMinute => 'menos de 1 min';

  @override
  String durationMinutes(int m) {
    return '$m min';
  }

  @override
  String durationHours(int h) {
    return '$h h';
  }

  @override
  String durationHoursMinutes(int h, int m) {
    return '$h h $m min';
  }

  @override
  String playlistMeta(String songs, String duration) {
    return '$songs · $duration';
  }

  @override
  String get coverFromTrack => 'Portada desde una canción';

  @override
  String get coverFromTrackLabel => 'Portada de una canción';

  @override
  String get currentCover => 'Portada actual';

  @override
  String get removeCover => 'Quitar portada';

  @override
  String get save => 'Guardar';

  @override
  String get nothingPlaying => 'Sin reproducción';

  @override
  String downloadingPercent(int percent) {
    return 'Descargando… $percent%';
  }

  @override
  String get preparing => 'Preparando…';

  @override
  String get shuffleOn => 'Aleatorio: activo';

  @override
  String get shuffle => 'Aleatorio';

  @override
  String get previous => 'Anterior';

  @override
  String get pause => 'Pausar';

  @override
  String get next => 'Siguiente';

  @override
  String get repeatOff => 'Repetir: desactivado';

  @override
  String get repeatAll => 'Repetir: toda la cola';

  @override
  String get repeatOne => 'Repetir: canción actual';

  @override
  String get radioOn => 'Radio: activa';

  @override
  String get radioOff => 'Radio: inactiva';

  @override
  String get removeFromFavorites => 'Quitar de favoritos';

  @override
  String get addToFavorites => 'Añadir a favoritos';

  @override
  String get unmute => 'Activar sonido';

  @override
  String get mute => 'Silenciar';

  @override
  String get unknownArtist => 'Artista desconocido';

  @override
  String get queue => 'Cola';

  @override
  String get queueTitle => 'Cola de reproducción';

  @override
  String get queueEmpty => 'La cola está vacía';

  @override
  String get queueEmptyHint =>
      'Reproduce una playlist o una canción para verla aquí';

  @override
  String get minimize => 'Minimizar';

  @override
  String get restore => 'Restaurar';

  @override
  String get maximize => 'Maximizar';

  @override
  String get close => 'Cerrar';

  @override
  String get noPlaylistsYet => 'No tienes playlists todavía. Crea una nueva.';

  @override
  String get addedToPlaylist => 'Añadida a la playlist';

  @override
  String get alreadyInPlaylist => 'Ya está en esta playlist';

  @override
  String get playerAnimation => 'Animación del reproductor';

  @override
  String get playerAnimationHint =>
      'Degradado animado en el player y las barras en reproducción';

  @override
  String get playerAnimationEnabled => 'Usar animación';

  @override
  String get playlistNamePrompt => 'Nombre de la playlist';

  @override
  String cantPlay(String error) {
    return 'No se pudo reproducir: $error';
  }

  @override
  String get language => 'Idioma';

  @override
  String get languageHint =>
      'El idioma de la interfaz se guarda entre sesiones';

  @override
  String get cache => 'Caché';

  @override
  String get cacheHint =>
      'Las canciones descargadas se guardan localmente para reproducir más rápido y sin conexión';

  @override
  String cacheUsed(String used, String limit) {
    return '$used de $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count archivos',
      one: '1 archivo',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Actualizar';

  @override
  String get clearCache => 'Vaciar caché';

  @override
  String get confirmClearCacheTitle => 'Vaciar caché';

  @override
  String get confirmClearCacheBody =>
      'Se eliminarán todas las canciones descargadas. Deberás volver a descargarlas para reproducirlas.';

  @override
  String get cacheCleared => 'Caché vaciada';

  @override
  String get cantClearCache => 'No se pudo vaciar el caché';

  @override
  String get about => 'Acerca de';

  @override
  String get version => 'Versión';

  @override
  String get discordPresence => 'Presencia de Discord';

  @override
  String get discordPresenceHint =>
      'Muestra en tu perfil de Discord la canción que estás escuchando';

  @override
  String get discordEnabled => 'Activar presencia';

  @override
  String get editMetadata => 'Editar metadatos';

  @override
  String get metadataTitle => 'Título';

  @override
  String get metadataArtist => 'Artista';

  @override
  String get metadataAlbum => 'Álbum';

  @override
  String get metadataCoverUrl => 'URL de la portada';

  @override
  String get metadataSaved => 'Metadatos actualizados';

  @override
  String get metadataSearchDeezer => 'Buscar en Deezer';

  @override
  String get metadataNotFound => 'No se encontró metadata en Deezer';

  @override
  String get metadataCoverError => 'No se pudo copiar la imagen';

  @override
  String get metadataSearchHint =>
      'Deezer buscará con el título y artista de este formulario';

  @override
  String get lyrics => 'Letras';

  @override
  String get lyricsTitle => 'Letras';

  @override
  String get syncLyrics => 'Sincronizar';

  @override
  String get refreshLyrics => 'Buscar letras';

  @override
  String get lyricsNoTrack => 'Sin reproducción';

  @override
  String get lyricsNotFound => 'No se encontraron letras';

  @override
  String get lyricsNotFoundHint =>
      'Prueba a corregir el artista o el título desde Editar metadatos';

  @override
  String get karaokeSweep => 'Karaoke';

  @override
  String get karaokeSweepHint =>
      'Ilumina la letra palabra por palabra al ritmo de la canción';

  @override
  String get done => 'Listo';

  @override
  String get karaokeSweepOn => 'Karaoke: activo';

  @override
  String get karaokeSweepOff => 'Karaoke: inactivo';

  @override
  String get syncLyricsTitle => 'Sincronización de letras';

  @override
  String get syncCurrent => 'Actual';

  @override
  String get lyricsSearchNoResults => 'No se encontraron resultados';

  @override
  String get lyricsSearchError => 'Error al buscar letras';

  @override
  String get lyricsSearchHint => 'Buscar letras (título artista)';

  @override
  String get editLyrics => 'Editar letra';

  @override
  String get useLyrics => 'Usar letra';

  @override
  String get editLyricsHint => 'Pega el LRC aquí: [mm:ss.xx] texto por línea';

  @override
  String get searchLyrics => 'Buscar letras';
}
