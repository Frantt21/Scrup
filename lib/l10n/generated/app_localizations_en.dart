// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => 'Settings';

  @override
  String get backToPlaylists => 'Back to playlists';

  @override
  String playbackErrorWithDetails(String details) {
    return 'Playback error: $details';
  }

  @override
  String get searchHint => 'Search songs on YouTube…';

  @override
  String get recentTitle => 'Recent';

  @override
  String get addToPlaylist => 'Add to playlist';

  @override
  String get recentEmptyTitle => 'Nothing played yet';

  @override
  String get recentEmptyHint => 'Use the search above to get started';

  @override
  String get backToHome => 'Back to home';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchStartHint => 'Search for a song to start playing it';

  @override
  String get searchNoResults => 'No results. Try another search.';

  @override
  String get cantCreatePlaylist => 'Could not create the playlist';

  @override
  String playlistCreated(String name) {
    return 'Playlist \"$name\" created';
  }

  @override
  String get deletePlaylistTitle => 'Delete playlist';

  @override
  String confirmDeletePlaylist(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get playlistDeleted => 'Playlist deleted';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get listViewTooltip => 'List view';

  @override
  String get gridViewTooltip => 'Grid view';

  @override
  String get noPlaylists => 'No playlists yet';

  @override
  String get createOneHere => 'Create one from here';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => 'New playlist';

  @override
  String get newPlaylistHint => 'Create a new one';

  @override
  String get playlistName => 'Name';

  @override
  String get playlistNameHint => 'My playlist';

  @override
  String get descriptionOptional => 'Description (optional)';

  @override
  String get descriptionHint => 'What is this playlist about?';

  @override
  String get description => 'Description';

  @override
  String get noCover => 'No cover';

  @override
  String get chooseImage => 'Choose image';

  @override
  String get changeImage => 'Change';

  @override
  String get removeImage => 'Remove image';

  @override
  String get images => 'Images';

  @override
  String get create => 'Create';

  @override
  String get play => 'Play';

  @override
  String get playShuffled => 'Play shuffled';

  @override
  String get emptyPlaylist => 'Empty playlist';

  @override
  String get emptyPlaylistHint => 'Add songs from the search';

  @override
  String get removeFromPlaylist => 'Remove from playlist';

  @override
  String get editPlaylist => 'Edit playlist';

  @override
  String get edit => 'Edit';

  @override
  String get playlistUpdated => 'Playlist updated';

  @override
  String get cantSaveChanges => 'Could not save the changes';

  @override
  String get lessThanOneMinute => 'less than 1 min';

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
  String get coverFromTrack => 'Cover from a song';

  @override
  String get coverFromTrackLabel => 'Cover from a song';

  @override
  String get currentCover => 'Current cover';

  @override
  String get removeCover => 'Remove cover';

  @override
  String get save => 'Save';

  @override
  String get nothingPlaying => 'Nothing playing';

  @override
  String downloadingPercent(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get preparing => 'Preparing…';

  @override
  String get shuffleOn => 'Shuffle: on';

  @override
  String get shuffle => 'Shuffle';

  @override
  String get previous => 'Previous';

  @override
  String get pause => 'Pause';

  @override
  String get next => 'Next';

  @override
  String get repeatOff => 'Repeat: off';

  @override
  String get repeatAll => 'Repeat: all';

  @override
  String get repeatOne => 'Repeat: one';

  @override
  String get radioOn => 'Radio: on';

  @override
  String get radioOff => 'Radio: off';

  @override
  String get removeFromFavorites => 'Remove from favorites';

  @override
  String get addToFavorites => 'Add to favorites';

  @override
  String get unmute => 'Unmute';

  @override
  String get mute => 'Mute';

  @override
  String get unknownArtist => 'Unknown artist';

  @override
  String get queue => 'Queue';

  @override
  String get queueTitle => 'Play queue';

  @override
  String get queueEmpty => 'The queue is empty';

  @override
  String get queueEmptyHint => 'Play a playlist or a song to see it here';

  @override
  String get minimize => 'Minimize';

  @override
  String get restore => 'Restore';

  @override
  String get maximize => 'Maximize';

  @override
  String get close => 'Close';

  @override
  String get noPlaylistsYet =>
      'You don\'t have any playlists yet. Create a new one.';

  @override
  String get addedToPlaylist => 'Added to playlist';

  @override
  String get alreadyInPlaylist => 'Already in this playlist';

  @override
  String get playerAnimation => 'Player animation';

  @override
  String get playerAnimationHint =>
      'Animated gradient in the player and the now-playing bars';

  @override
  String get playerAnimationEnabled => 'Use animation';

  @override
  String get playlistNamePrompt => 'Playlist name';

  @override
  String cantPlay(String error) {
    return 'Could not play: $error';
  }

  @override
  String get language => 'Language';

  @override
  String get languageHint => 'The interface language is saved between sessions';

  @override
  String get cache => 'Cache';

  @override
  String get cacheHint =>
      'Downloaded songs are stored locally for faster playback';

  @override
  String cacheUsed(String used, String limit) {
    return '$used of $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Refresh';

  @override
  String get clearCache => 'Clear cache';

  @override
  String get confirmClearCacheTitle => 'Clear cache';

  @override
  String get confirmClearCacheBody =>
      'All downloaded songs will be deleted. You\'ll need to download them again to play them.';

  @override
  String get cacheCleared => 'Cache cleared';

  @override
  String get cantClearCache => 'Could not clear the cache';

  @override
  String get about => 'About';

  @override
  String get version => 'Version';

  @override
  String get discordPresence => 'Discord Presence';

  @override
  String get discordPresenceHint =>
      'Show what you\'re listening to on your Discord profile';

  @override
  String get discordEnabled => 'Enable presence';

  @override
  String get editMetadata => 'Edit metadata';

  @override
  String get metadataTitle => 'Title';

  @override
  String get metadataArtist => 'Artist';

  @override
  String get metadataAlbum => 'Album';

  @override
  String get metadataCoverUrl => 'Cover URL';

  @override
  String get metadataSaved => 'Metadata updated';

  @override
  String get metadataSearchDeezer => 'Search on Deezer';

  @override
  String get metadataNotFound => 'No metadata found on Deezer';

  @override
  String get metadataCoverError => 'Could not copy the image';

  @override
  String get metadataSearchHint =>
      'Deezer will search using the title and artist from this form';

  @override
  String get lyrics => 'Lyrics';

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get syncLyrics => 'Sync';

  @override
  String get refreshLyrics => 'Search lyrics';

  @override
  String get lyricsNoTrack => 'Nothing playing';

  @override
  String get lyricsNotFound => 'No lyrics found';

  @override
  String get lyricsNotFoundHint =>
      'Try fixing the artist or title from Edit metadata';

  @override
  String get karaokeSweep => 'Karaoke';

  @override
  String get karaokeSweepHint =>
      'Highlights the lyrics word by word along the song';
}
