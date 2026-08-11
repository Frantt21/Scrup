import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_pt.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('ja'),
    Locale('ko'),
    Locale('pt'),
    Locale('pt', 'BR'),
    Locale('ru'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In es, this message translates to:
  /// **'Scrup'**
  String get appTitle;

  /// No description provided for @settings.
  ///
  /// In es, this message translates to:
  /// **'Configuración'**
  String get settings;

  /// No description provided for @backToPlaylists.
  ///
  /// In es, this message translates to:
  /// **'Volver a playlists'**
  String get backToPlaylists;

  /// No description provided for @playbackErrorWithDetails.
  ///
  /// In es, this message translates to:
  /// **'Error de reproducción: {details}'**
  String playbackErrorWithDetails(String details);

  /// No description provided for @searchHint.
  ///
  /// In es, this message translates to:
  /// **'Buscar canciones en YouTube…'**
  String get searchHint;

  /// No description provided for @recentTitle.
  ///
  /// In es, this message translates to:
  /// **'Recientes'**
  String get recentTitle;

  /// No description provided for @addToPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Añadir a playlist'**
  String get addToPlaylist;

  /// No description provided for @recentEmptyTitle.
  ///
  /// In es, this message translates to:
  /// **'Aún no has reproducido nada'**
  String get recentEmptyTitle;

  /// No description provided for @recentEmptyHint.
  ///
  /// In es, this message translates to:
  /// **'Usa la búsqueda de arriba para empezar'**
  String get recentEmptyHint;

  /// No description provided for @backToHome.
  ///
  /// In es, this message translates to:
  /// **'Volver al inicio'**
  String get backToHome;

  /// No description provided for @searchTitle.
  ///
  /// In es, this message translates to:
  /// **'Buscar'**
  String get searchTitle;

  /// No description provided for @searchStartHint.
  ///
  /// In es, this message translates to:
  /// **'Busca una canción para empezar a reproducirla'**
  String get searchStartHint;

  /// No description provided for @searchNoResults.
  ///
  /// In es, this message translates to:
  /// **'Sin resultados. Prueba otra búsqueda.'**
  String get searchNoResults;

  /// No description provided for @cantCreatePlaylist.
  ///
  /// In es, this message translates to:
  /// **'No se pudo crear la playlist'**
  String get cantCreatePlaylist;

  /// No description provided for @playlistCreated.
  ///
  /// In es, this message translates to:
  /// **'Playlist \"{name}\" creada'**
  String playlistCreated(String name);

  /// No description provided for @deletePlaylistTitle.
  ///
  /// In es, this message translates to:
  /// **'Eliminar playlist'**
  String get deletePlaylistTitle;

  /// No description provided for @confirmDeletePlaylist.
  ///
  /// In es, this message translates to:
  /// **'¿Eliminar \"{name}\"?'**
  String confirmDeletePlaylist(String name);

  /// No description provided for @cancel.
  ///
  /// In es, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In es, this message translates to:
  /// **'Eliminar'**
  String get delete;

  /// No description provided for @playlistDeleted.
  ///
  /// In es, this message translates to:
  /// **'Playlist eliminada'**
  String get playlistDeleted;

  /// No description provided for @playlistsTitle.
  ///
  /// In es, this message translates to:
  /// **'Playlists'**
  String get playlistsTitle;

  /// No description provided for @listViewTooltip.
  ///
  /// In es, this message translates to:
  /// **'Vista de lista'**
  String get listViewTooltip;

  /// No description provided for @gridViewTooltip.
  ///
  /// In es, this message translates to:
  /// **'Vista de cuadrícula'**
  String get gridViewTooltip;

  /// No description provided for @noPlaylists.
  ///
  /// In es, this message translates to:
  /// **'Aún no tienes playlists'**
  String get noPlaylists;

  /// No description provided for @createOneHere.
  ///
  /// In es, this message translates to:
  /// **'Crea una desde aquí'**
  String get createOneHere;

  /// No description provided for @songCount.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 canción} other{{count} canciones}}'**
  String songCount(int count);

  /// No description provided for @newPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Nueva playlist'**
  String get newPlaylist;

  /// No description provided for @newPlaylistHint.
  ///
  /// In es, this message translates to:
  /// **'Crea una nueva'**
  String get newPlaylistHint;

  /// No description provided for @playlistName.
  ///
  /// In es, this message translates to:
  /// **'Nombre'**
  String get playlistName;

  /// No description provided for @playlistNameHint.
  ///
  /// In es, this message translates to:
  /// **'Mi playlist'**
  String get playlistNameHint;

  /// No description provided for @descriptionOptional.
  ///
  /// In es, this message translates to:
  /// **'Descripción (opcional)'**
  String get descriptionOptional;

  /// No description provided for @descriptionHint.
  ///
  /// In es, this message translates to:
  /// **'¿De qué trata esta playlist?'**
  String get descriptionHint;

  /// No description provided for @description.
  ///
  /// In es, this message translates to:
  /// **'Descripción'**
  String get description;

  /// No description provided for @noCover.
  ///
  /// In es, this message translates to:
  /// **'Sin portada'**
  String get noCover;

  /// No description provided for @chooseImage.
  ///
  /// In es, this message translates to:
  /// **'Elegir imagen'**
  String get chooseImage;

  /// No description provided for @changeImage.
  ///
  /// In es, this message translates to:
  /// **'Cambiar'**
  String get changeImage;

  /// No description provided for @removeImage.
  ///
  /// In es, this message translates to:
  /// **'Quitar imagen'**
  String get removeImage;

  /// No description provided for @images.
  ///
  /// In es, this message translates to:
  /// **'Imágenes'**
  String get images;

  /// No description provided for @create.
  ///
  /// In es, this message translates to:
  /// **'Crear'**
  String get create;

  /// No description provided for @play.
  ///
  /// In es, this message translates to:
  /// **'Reproducir'**
  String get play;

  /// No description provided for @playShuffled.
  ///
  /// In es, this message translates to:
  /// **'Reproducir en aleatorio'**
  String get playShuffled;

  /// No description provided for @emptyPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Playlist vacía'**
  String get emptyPlaylist;

  /// No description provided for @emptyPlaylistHint.
  ///
  /// In es, this message translates to:
  /// **'Añade canciones desde la búsqueda'**
  String get emptyPlaylistHint;

  /// No description provided for @removeFromPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Quitar de la playlist'**
  String get removeFromPlaylist;

  /// No description provided for @editPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Editar playlist'**
  String get editPlaylist;

  /// No description provided for @edit.
  ///
  /// In es, this message translates to:
  /// **'Editar'**
  String get edit;

  /// No description provided for @playlistUpdated.
  ///
  /// In es, this message translates to:
  /// **'Playlist actualizada'**
  String get playlistUpdated;

  /// No description provided for @cantSaveChanges.
  ///
  /// In es, this message translates to:
  /// **'No se pudo guardar los cambios'**
  String get cantSaveChanges;

  /// No description provided for @lessThanOneMinute.
  ///
  /// In es, this message translates to:
  /// **'menos de 1 min'**
  String get lessThanOneMinute;

  /// No description provided for @durationMinutes.
  ///
  /// In es, this message translates to:
  /// **'{m} min'**
  String durationMinutes(int m);

  /// No description provided for @durationHours.
  ///
  /// In es, this message translates to:
  /// **'{h} h'**
  String durationHours(int h);

  /// No description provided for @durationHoursMinutes.
  ///
  /// In es, this message translates to:
  /// **'{h} h {m} min'**
  String durationHoursMinutes(int h, int m);

  /// No description provided for @playlistMeta.
  ///
  /// In es, this message translates to:
  /// **'{songs} · {duration}'**
  String playlistMeta(String songs, String duration);

  /// No description provided for @coverFromTrack.
  ///
  /// In es, this message translates to:
  /// **'Portada desde una canción'**
  String get coverFromTrack;

  /// No description provided for @coverFromTrackLabel.
  ///
  /// In es, this message translates to:
  /// **'Portada de una canción'**
  String get coverFromTrackLabel;

  /// No description provided for @currentCover.
  ///
  /// In es, this message translates to:
  /// **'Portada actual'**
  String get currentCover;

  /// No description provided for @removeCover.
  ///
  /// In es, this message translates to:
  /// **'Quitar portada'**
  String get removeCover;

  /// No description provided for @save.
  ///
  /// In es, this message translates to:
  /// **'Guardar'**
  String get save;

  /// No description provided for @nothingPlaying.
  ///
  /// In es, this message translates to:
  /// **'Sin reproducción'**
  String get nothingPlaying;

  /// No description provided for @downloadingPercent.
  ///
  /// In es, this message translates to:
  /// **'Descargando… {percent}%'**
  String downloadingPercent(int percent);

  /// No description provided for @preparing.
  ///
  /// In es, this message translates to:
  /// **'Preparando…'**
  String get preparing;

  /// No description provided for @shuffleOn.
  ///
  /// In es, this message translates to:
  /// **'Aleatorio: activo'**
  String get shuffleOn;

  /// No description provided for @shuffle.
  ///
  /// In es, this message translates to:
  /// **'Aleatorio'**
  String get shuffle;

  /// No description provided for @previous.
  ///
  /// In es, this message translates to:
  /// **'Anterior'**
  String get previous;

  /// No description provided for @pause.
  ///
  /// In es, this message translates to:
  /// **'Pausar'**
  String get pause;

  /// No description provided for @next.
  ///
  /// In es, this message translates to:
  /// **'Siguiente'**
  String get next;

  /// No description provided for @repeatOff.
  ///
  /// In es, this message translates to:
  /// **'Repetir: desactivado'**
  String get repeatOff;

  /// No description provided for @repeatAll.
  ///
  /// In es, this message translates to:
  /// **'Repetir: toda la cola'**
  String get repeatAll;

  /// No description provided for @repeatOne.
  ///
  /// In es, this message translates to:
  /// **'Repetir: canción actual'**
  String get repeatOne;

  /// No description provided for @radioOn.
  ///
  /// In es, this message translates to:
  /// **'Radio: activa'**
  String get radioOn;

  /// No description provided for @radioOff.
  ///
  /// In es, this message translates to:
  /// **'Radio: inactiva'**
  String get radioOff;

  /// No description provided for @removeFromFavorites.
  ///
  /// In es, this message translates to:
  /// **'Quitar de favoritos'**
  String get removeFromFavorites;

  /// No description provided for @addToFavorites.
  ///
  /// In es, this message translates to:
  /// **'Añadir a favoritos'**
  String get addToFavorites;

  /// No description provided for @unmute.
  ///
  /// In es, this message translates to:
  /// **'Activar sonido'**
  String get unmute;

  /// No description provided for @mute.
  ///
  /// In es, this message translates to:
  /// **'Silenciar'**
  String get mute;

  /// No description provided for @unknownArtist.
  ///
  /// In es, this message translates to:
  /// **'Artista desconocido'**
  String get unknownArtist;

  /// No description provided for @queue.
  ///
  /// In es, this message translates to:
  /// **'Cola'**
  String get queue;

  /// No description provided for @queueTitle.
  ///
  /// In es, this message translates to:
  /// **'Cola de reproducción'**
  String get queueTitle;

  /// No description provided for @queueEmpty.
  ///
  /// In es, this message translates to:
  /// **'La cola está vacía'**
  String get queueEmpty;

  /// No description provided for @queueEmptyHint.
  ///
  /// In es, this message translates to:
  /// **'Reproduce una playlist o una canción para verla aquí'**
  String get queueEmptyHint;

  /// No description provided for @minimize.
  ///
  /// In es, this message translates to:
  /// **'Minimizar'**
  String get minimize;

  /// No description provided for @restore.
  ///
  /// In es, this message translates to:
  /// **'Restaurar'**
  String get restore;

  /// No description provided for @maximize.
  ///
  /// In es, this message translates to:
  /// **'Maximizar'**
  String get maximize;

  /// No description provided for @close.
  ///
  /// In es, this message translates to:
  /// **'Cerrar'**
  String get close;

  /// No description provided for @noPlaylistsYet.
  ///
  /// In es, this message translates to:
  /// **'No tienes playlists todavía. Crea una nueva.'**
  String get noPlaylistsYet;

  /// No description provided for @addedToPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Añadida a la playlist'**
  String get addedToPlaylist;

  /// No description provided for @alreadyInPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Ya está en esta playlist'**
  String get alreadyInPlaylist;

  /// No description provided for @playerAnimation.
  ///
  /// In es, this message translates to:
  /// **'Animación del reproductor'**
  String get playerAnimation;

  /// No description provided for @playerAnimationHint.
  ///
  /// In es, this message translates to:
  /// **'Degradado animado de dos tonos en el player'**
  String get playerAnimationHint;

  /// No description provided for @playerAnimationEnabled.
  ///
  /// In es, this message translates to:
  /// **'Usar animación'**
  String get playerAnimationEnabled;

  /// No description provided for @playlistNamePrompt.
  ///
  /// In es, this message translates to:
  /// **'Nombre de la playlist'**
  String get playlistNamePrompt;

  /// No description provided for @cantPlay.
  ///
  /// In es, this message translates to:
  /// **'No se pudo reproducir: {error}'**
  String cantPlay(String error);

  /// No description provided for @language.
  ///
  /// In es, this message translates to:
  /// **'Idioma'**
  String get language;

  /// No description provided for @languageHint.
  ///
  /// In es, this message translates to:
  /// **'El idioma de la interfaz se guarda entre sesiones'**
  String get languageHint;

  /// No description provided for @cache.
  ///
  /// In es, this message translates to:
  /// **'Caché'**
  String get cache;

  /// No description provided for @cacheHint.
  ///
  /// In es, this message translates to:
  /// **'Las canciones descargadas se guardan localmente para reproducir más rápido y sin conexión'**
  String get cacheHint;

  /// No description provided for @cacheUsed.
  ///
  /// In es, this message translates to:
  /// **'{used} de {limit}'**
  String cacheUsed(String used, String limit);

  /// No description provided for @cacheFiles.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 archivo} other{{count} archivos}}'**
  String cacheFiles(int count);

  /// No description provided for @refresh.
  ///
  /// In es, this message translates to:
  /// **'Actualizar'**
  String get refresh;

  /// No description provided for @clearCache.
  ///
  /// In es, this message translates to:
  /// **'Vaciar caché'**
  String get clearCache;

  /// No description provided for @confirmClearCacheTitle.
  ///
  /// In es, this message translates to:
  /// **'Vaciar caché'**
  String get confirmClearCacheTitle;

  /// No description provided for @confirmClearCacheBody.
  ///
  /// In es, this message translates to:
  /// **'Se eliminarán todas las canciones descargadas. Deberás volver a descargarlas para reproducirlas.'**
  String get confirmClearCacheBody;

  /// No description provided for @cacheCleared.
  ///
  /// In es, this message translates to:
  /// **'Caché vaciada'**
  String get cacheCleared;

  /// No description provided for @cantClearCache.
  ///
  /// In es, this message translates to:
  /// **'No se pudo vaciar el caché'**
  String get cantClearCache;

  /// No description provided for @about.
  ///
  /// In es, this message translates to:
  /// **'Acerca de'**
  String get about;

  /// No description provided for @version.
  ///
  /// In es, this message translates to:
  /// **'Versión'**
  String get version;

  /// No description provided for @discordPresence.
  ///
  /// In es, this message translates to:
  /// **'Presencia de Discord'**
  String get discordPresence;

  /// No description provided for @discordPresenceHint.
  ///
  /// In es, this message translates to:
  /// **'Muestra en tu perfil de Discord la canción que estás escuchando'**
  String get discordPresenceHint;

  /// No description provided for @discordEnabled.
  ///
  /// In es, this message translates to:
  /// **'Activar presencia'**
  String get discordEnabled;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'en',
    'es',
    'ja',
    'ko',
    'pt',
    'ru',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'pt':
      {
        switch (locale.countryCode) {
          case 'BR':
            return AppLocalizationsPtBr();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'pt':
      return AppLocalizationsPt();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
