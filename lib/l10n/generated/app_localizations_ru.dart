// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => 'Настройки';

  @override
  String get backToPlaylists => 'Вернуться к плейлистам';

  @override
  String playbackErrorWithDetails(String details) {
    return 'Ошибка воспроизведения: $details';
  }

  @override
  String get searchHint => 'Искать песни на YouTube…';

  @override
  String get recentTitle => 'Недавние';

  @override
  String get addToPlaylist => 'Добавить в плейлист';

  @override
  String get recentEmptyTitle => 'Вы ещё ничего не воспроизводили';

  @override
  String get recentEmptyHint => 'Используйте поиск выше, чтобы начать';

  @override
  String get backToHome => 'Вернуться на главную';

  @override
  String get searchTitle => 'Поиск';

  @override
  String get searchStartHint =>
      'Найдите песню, чтобы начать её воспроизведение';

  @override
  String get searchNoResults => 'Ничего не найдено. Попробуйте другой запрос.';

  @override
  String get cantCreatePlaylist => 'Не удалось создать плейлист';

  @override
  String playlistCreated(String name) {
    return 'Плейлист \"$name\" создан';
  }

  @override
  String get deletePlaylistTitle => 'Удалить плейлист';

  @override
  String confirmDeletePlaylist(String name) {
    return 'Удалить \"$name\"?';
  }

  @override
  String get cancel => 'Отмена';

  @override
  String get delete => 'Удалить';

  @override
  String get playlistDeleted => 'Плейлист удалён';

  @override
  String get playlistsTitle => 'Плейлисты';

  @override
  String get listViewTooltip => 'Вид списком';

  @override
  String get gridViewTooltip => 'Вид сеткой';

  @override
  String get noPlaylists => 'Плейлистов пока нет';

  @override
  String get createOneHere => 'Создайте его здесь';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count песни',
      many: '$count песен',
      few: '$count песни',
      one: '$count песня',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => 'Новый плейлист';

  @override
  String get newPlaylistHint => 'Создать новый';

  @override
  String get playlistName => 'Название';

  @override
  String get playlistNameHint => 'Мой плейлист';

  @override
  String get descriptionOptional => 'Описание (необязательно)';

  @override
  String get descriptionHint => 'О чём этот плейлист?';

  @override
  String get description => 'Описание';

  @override
  String get noCover => 'Без обложки';

  @override
  String get chooseImage => 'Выбрать изображение';

  @override
  String get changeImage => 'Изменить';

  @override
  String get removeImage => 'Убрать изображение';

  @override
  String get images => 'Изображения';

  @override
  String get create => 'Создать';

  @override
  String get play => 'Воспроизвести';

  @override
  String get playShuffled => 'Воспроизвести вперемешку';

  @override
  String get emptyPlaylist => 'Пустой плейлист';

  @override
  String get emptyPlaylistHint => 'Добавьте песни через поиск';

  @override
  String get removeFromPlaylist => 'Убрать из плейлиста';

  @override
  String get editPlaylist => 'Изменить плейлист';

  @override
  String get edit => 'Изменить';

  @override
  String get playlistUpdated => 'Плейлист обновлён';

  @override
  String get cantSaveChanges => 'Не удалось сохранить изменения';

  @override
  String get lessThanOneMinute => 'меньше 1 мин';

  @override
  String durationMinutes(int m) {
    return '$m мин';
  }

  @override
  String durationHours(int h) {
    return '$h ч';
  }

  @override
  String durationHoursMinutes(int h, int m) {
    return '$h ч $m мин';
  }

  @override
  String playlistMeta(String songs, String duration) {
    return '$songs · $duration';
  }

  @override
  String get coverFromTrack => 'Обложка из песни';

  @override
  String get coverFromTrackLabel => 'Обложка из песни';

  @override
  String get currentCover => 'Текущая обложка';

  @override
  String get removeCover => 'Убрать обложку';

  @override
  String get save => 'Сохранить';

  @override
  String get nothingPlaying => 'Ничего не играет';

  @override
  String downloadingPercent(int percent) {
    return 'Загрузка… $percent%';
  }

  @override
  String get preparing => 'Подготовка…';

  @override
  String get shuffleOn => 'Перемешать: вкл';

  @override
  String get shuffle => 'Перемешать';

  @override
  String get previous => 'Предыдущая';

  @override
  String get pause => 'Пауза';

  @override
  String get next => 'Следующая';

  @override
  String get repeatOff => 'Повтор: выкл';

  @override
  String get repeatAll => 'Повтор: вся очередь';

  @override
  String get repeatOne => 'Повтор: текущая песня';

  @override
  String get radioOn => 'Радио: вкл';

  @override
  String get radioOff => 'Радио: выкл';

  @override
  String get removeFromFavorites => 'Убрать из избранного';

  @override
  String get addToFavorites => 'Добавить в избранное';

  @override
  String get unmute => 'Включить звук';

  @override
  String get mute => 'Выключить звук';

  @override
  String get unknownArtist => 'Неизвестный исполнитель';

  @override
  String get queue => 'Очередь';

  @override
  String get queueTitle => 'Очередь воспроизведения';

  @override
  String get queueEmpty => 'Очередь пуста';

  @override
  String get queueEmptyHint =>
      'Воспроизведите плейлист или песню, чтобы увидеть её здесь';

  @override
  String get minimize => 'Свернуть';

  @override
  String get restore => 'Восстановить';

  @override
  String get maximize => 'Развернуть';

  @override
  String get close => 'Закрыть';

  @override
  String get noPlaylistsYet => 'У вас ещё нет плейлистов. Создайте новый.';

  @override
  String get addedToPlaylist => 'Добавлено в плейлист';

  @override
  String get alreadyInPlaylist => 'Уже в этом плейлисте';

  @override
  String get playerAnimation => 'Анимация плеера';

  @override
  String get playerAnimationHint =>
      'Анимированный градиент в плеере и индикатор воспроизведения';

  @override
  String get playerAnimationEnabled => 'Использовать анимацию';

  @override
  String get playlistNamePrompt => 'Название плейлиста';

  @override
  String cantPlay(String error) {
    return 'Не удалось воспроизвести: $error';
  }

  @override
  String get language => 'Язык';

  @override
  String get languageHint => 'Язык интерфейса сохраняется между сеансами';

  @override
  String get cache => 'Кэш';

  @override
  String get cacheHint =>
      'Скачанные песни хранятся локально для более быстрого воспроизведения';

  @override
  String cacheUsed(String used, String limit) {
    return '$used из $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файлов',
      many: '$count файлов',
      few: '$count файла',
      one: '$count файл',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Обновить';

  @override
  String get clearCache => 'Очистить кэш';

  @override
  String get confirmClearCacheTitle => 'Очистить кэш';

  @override
  String get confirmClearCacheBody =>
      'Все скачанные песни будут удалены. Чтобы снова их воспроизвести, потребуется загрузка заново.';

  @override
  String get cacheCleared => 'Кэш очищен';

  @override
  String get cantClearCache => 'Не удалось очистить кэш';

  @override
  String get about => 'О программе';

  @override
  String get version => 'Версия';

  @override
  String get discordPresence => 'Присутствие в Discord';

  @override
  String get discordPresenceHint =>
      'Показывает в вашем профиле Discord песню, которую вы слушаете';

  @override
  String get discordEnabled => 'Включить присутствие';

  @override
  String get editMetadata => 'Редактировать метаданные';

  @override
  String get metadataTitle => 'Название';

  @override
  String get metadataArtist => 'Исполнитель';

  @override
  String get metadataAlbum => 'Альбом';

  @override
  String get metadataCoverUrl => 'URL обложки';

  @override
  String get metadataSaved => 'Метаданные обновлены';

  @override
  String get metadataSearchDeezer => 'Искать на Deezer';

  @override
  String get metadataNotFound => 'Метаданные на Deezer не найдены';

  @override
  String get metadataCoverError => 'Не удалось скопировать изображение';

  @override
  String get metadataSearchHint =>
      'Deezer выполнит поиск по названию и исполнителю из этой формы';

  @override
  String get lyrics => 'Текст';

  @override
  String get lyricsTitle => 'Текст песни';

  @override
  String get syncLyrics => 'Синхр.';

  @override
  String get refreshLyrics => 'Найти текст';

  @override
  String get lyricsNoTrack => 'Ничего не играет';

  @override
  String get lyricsNotFound => 'Текст не найден';

  @override
  String get lyricsNotFoundHint =>
      'Попробуйте исправить исполнителя или название в «Редактировать метаданные»';

  @override
  String get karaokeSweep => 'Караоке';

  @override
  String get karaokeSweepHint =>
      'Подсвечивает текст слово за словом в такт песне';

  @override
  String get done => 'Готово';

  @override
  String get karaokeSweepOn => 'Караоке: вкл';

  @override
  String get karaokeSweepOff => 'Караоке: выкл';

  @override
  String get skipSilence => 'Пропускать тишину';

  @override
  String get skipSilenceHint =>
      'Автоматически пропускает паузы без музыки во время воспроизведения';

  @override
  String get syncLyricsTitle => 'Синхронизация текста';

  @override
  String get syncCurrent => 'Текущая';

  @override
  String get lyricsSearchNoResults => 'Результаты не найдены';

  @override
  String get lyricsSearchError => 'Ошибка поиска текста';

  @override
  String get lyricsSearchHint => 'Поиск текста (название исполнитель)';

  @override
  String get editLyrics => 'Редактировать текст';

  @override
  String get useLyrics => 'Использовать текст';

  @override
  String get editLyricsHint => 'Вставьте LRC здесь: [мм:сс.сс] текст на строку';

  @override
  String get searchLyrics => 'Найти текст';
}
