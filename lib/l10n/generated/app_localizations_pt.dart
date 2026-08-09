// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => 'Configurações';

  @override
  String get backToPlaylists => 'Voltar às playlists';

  @override
  String playbackErrorWithDetails(String details) {
    return 'Erro de reprodução: $details';
  }

  @override
  String get searchHint => 'Buscar músicas no YouTube…';

  @override
  String get recentTitle => 'Recentes';

  @override
  String get addToPlaylist => 'Adicionar à playlist';

  @override
  String get recentEmptyTitle => 'Você ainda não reproduziu nada';

  @override
  String get recentEmptyHint => 'Use a busca acima para começar';

  @override
  String get backToHome => 'Voltar ao início';

  @override
  String get searchTitle => 'Buscar';

  @override
  String get searchStartHint => 'Busque uma música para começar a reproduzi-la';

  @override
  String get searchNoResults => 'Sem resultados. Tente outra busca.';

  @override
  String get cantCreatePlaylist => 'Não foi possível criar a playlist';

  @override
  String playlistCreated(String name) {
    return 'Playlist \"$name\" criada';
  }

  @override
  String get deletePlaylistTitle => 'Excluir playlist';

  @override
  String confirmDeletePlaylist(String name) {
    return 'Excluir \"$name\"?';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Excluir';

  @override
  String get playlistDeleted => 'Playlist excluída';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get listViewTooltip => 'Vista em lista';

  @override
  String get gridViewTooltip => 'Vista em grade';

  @override
  String get noPlaylists => 'Você ainda não tem playlists';

  @override
  String get createOneHere => 'Crie uma por aqui';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count músicas',
      one: '1 música',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => 'Nova playlist';

  @override
  String get newPlaylistHint => 'Criar uma nova';

  @override
  String get playlistName => 'Nome';

  @override
  String get playlistNameHint => 'Minha playlist';

  @override
  String get descriptionOptional => 'Descrição (opcional)';

  @override
  String get descriptionHint => 'Sobre o que é esta playlist?';

  @override
  String get description => 'Descrição';

  @override
  String get noCover => 'Sem capa';

  @override
  String get chooseImage => 'Escolher imagem';

  @override
  String get changeImage => 'Alterar';

  @override
  String get removeImage => 'Remover imagem';

  @override
  String get images => 'Imagens';

  @override
  String get create => 'Criar';

  @override
  String get play => 'Reproduzir';

  @override
  String get playShuffled => 'Reproduzir embaralhado';

  @override
  String get emptyPlaylist => 'Playlist vazia';

  @override
  String get emptyPlaylistHint => 'Adicione músicas pela busca';

  @override
  String get removeFromPlaylist => 'Remover da playlist';

  @override
  String get editPlaylist => 'Editar playlist';

  @override
  String get edit => 'Editar';

  @override
  String get playlistUpdated => 'Playlist atualizada';

  @override
  String get cantSaveChanges => 'Não foi possível salvar as alterações';

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
  String get coverFromTrack => 'Capa a partir de uma música';

  @override
  String get coverFromTrackLabel => 'Capa de uma música';

  @override
  String get currentCover => 'Capa atual';

  @override
  String get removeCover => 'Remover capa';

  @override
  String get save => 'Salvar';

  @override
  String get nothingPlaying => 'Nada em reprodução';

  @override
  String downloadingPercent(int percent) {
    return 'Baixando… $percent%';
  }

  @override
  String get preparing => 'Preparando…';

  @override
  String get shuffleOn => 'Embaralhar: ativado';

  @override
  String get shuffle => 'Embaralhar';

  @override
  String get previous => 'Anterior';

  @override
  String get pause => 'Pausar';

  @override
  String get next => 'Próxima';

  @override
  String get repeatOff => 'Repetir: desativado';

  @override
  String get repeatAll => 'Repetir: toda a fila';

  @override
  String get repeatOne => 'Repetir: música atual';

  @override
  String get radioOn => 'Rádio: ativado';

  @override
  String get radioOff => 'Rádio: desativado';

  @override
  String get removeFromFavorites => 'Remover dos favoritos';

  @override
  String get addToFavorites => 'Adicionar aos favoritos';

  @override
  String get unmute => 'Ativar som';

  @override
  String get mute => 'Silenciar';

  @override
  String get unknownArtist => 'Artista desconhecido';

  @override
  String get minimize => 'Minimizar';

  @override
  String get restore => 'Restaurar';

  @override
  String get maximize => 'Maximizar';

  @override
  String get close => 'Fechar';

  @override
  String get noPlaylistsYet => 'Você ainda não tem playlists. Crie uma nova.';

  @override
  String get addedToPlaylist => 'Adicionada à playlist';

  @override
  String get playlistNamePrompt => 'Nome da playlist';

  @override
  String cantPlay(String error) {
    return 'Não foi possível reproduzir: $error';
  }

  @override
  String get language => 'Idioma';

  @override
  String get languageHint => 'O idioma da interface é salvo entre sessões';

  @override
  String get cache => 'Cache';

  @override
  String get cacheHint =>
      'As músicas baixadas são armazenadas localmente para reprodução mais rápida';

  @override
  String cacheUsed(String used, String limit) {
    return '$used de $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count arquivos',
      one: '1 arquivo',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Atualizar';

  @override
  String get clearCache => 'Limpar cache';

  @override
  String get confirmClearCacheTitle => 'Limpar cache';

  @override
  String get confirmClearCacheBody =>
      'Todas as músicas baixadas serão excluídas. Você precisará baixá-las novamente para reproduzi-las.';

  @override
  String get cacheCleared => 'Cache limpo';

  @override
  String get cantClearCache => 'Não foi possível limpar o cache';

  @override
  String get about => 'Sobre';

  @override
  String get version => 'Versão';

  @override
  String get discordPresence => 'Presença do Discord';

  @override
  String get discordPresenceHint =>
      'Mostra no seu perfil do Discord a música que você está a ouvir';

  @override
  String get discordEnabled => 'Ativar presença';

  @override
  String get discordClientId => 'ID da aplicação';

  @override
  String get discordClientIdHint =>
      'Crie uma app em discord.com/developers e cole aqui o ID da aplicação';

  @override
  String get discordRequiresClientId =>
      'Precisa de criar uma app no Portal de Desenvolvedores do Discord para a presença aparecer';
}

/// The translations for Portuguese, as used in Brazil (`pt_BR`).
class AppLocalizationsPtBr extends AppLocalizationsPt {
  AppLocalizationsPtBr() : super('pt_BR');

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => 'Configurações';

  @override
  String get backToPlaylists => 'Voltar às playlists';

  @override
  String playbackErrorWithDetails(String details) {
    return 'Erro de reprodução: $details';
  }

  @override
  String get searchHint => 'Buscar músicas no YouTube…';

  @override
  String get recentTitle => 'Recentes';

  @override
  String get addToPlaylist => 'Adicionar à playlist';

  @override
  String get recentEmptyTitle => 'Você ainda não reproduziu nada';

  @override
  String get recentEmptyHint => 'Use a busca acima para começar';

  @override
  String get backToHome => 'Voltar ao início';

  @override
  String get searchTitle => 'Buscar';

  @override
  String get searchStartHint => 'Busque uma música para começar a reproduzi-la';

  @override
  String get searchNoResults => 'Sem resultados. Tente outra busca.';

  @override
  String get cantCreatePlaylist => 'Não foi possível criar a playlist';

  @override
  String playlistCreated(String name) {
    return 'Playlist \"$name\" criada';
  }

  @override
  String get deletePlaylistTitle => 'Excluir playlist';

  @override
  String confirmDeletePlaylist(String name) {
    return 'Excluir \"$name\"?';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Excluir';

  @override
  String get playlistDeleted => 'Playlist excluída';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get listViewTooltip => 'Vista em lista';

  @override
  String get gridViewTooltip => 'Vista em grade';

  @override
  String get noPlaylists => 'Você ainda não tem playlists';

  @override
  String get createOneHere => 'Crie uma por aqui';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count músicas',
      one: '1 música',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => 'Nova playlist';

  @override
  String get newPlaylistHint => 'Criar uma nova';

  @override
  String get playlistName => 'Nome';

  @override
  String get playlistNameHint => 'Minha playlist';

  @override
  String get descriptionOptional => 'Descrição (opcional)';

  @override
  String get descriptionHint => 'Sobre o que é esta playlist?';

  @override
  String get description => 'Descrição';

  @override
  String get noCover => 'Sem capa';

  @override
  String get chooseImage => 'Escolher imagem';

  @override
  String get changeImage => 'Alterar';

  @override
  String get removeImage => 'Remover imagem';

  @override
  String get images => 'Imagens';

  @override
  String get create => 'Criar';

  @override
  String get play => 'Reproduzir';

  @override
  String get playShuffled => 'Reproduzir embaralhado';

  @override
  String get emptyPlaylist => 'Playlist vazia';

  @override
  String get emptyPlaylistHint => 'Adicione músicas pela busca';

  @override
  String get removeFromPlaylist => 'Remover da playlist';

  @override
  String get editPlaylist => 'Editar playlist';

  @override
  String get edit => 'Editar';

  @override
  String get playlistUpdated => 'Playlist atualizada';

  @override
  String get cantSaveChanges => 'Não foi possível salvar as alterações';

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
  String get coverFromTrack => 'Capa a partir de uma música';

  @override
  String get coverFromTrackLabel => 'Capa de uma música';

  @override
  String get currentCover => 'Capa atual';

  @override
  String get removeCover => 'Remover capa';

  @override
  String get save => 'Salvar';

  @override
  String get nothingPlaying => 'Nada em reprodução';

  @override
  String downloadingPercent(int percent) {
    return 'Baixando… $percent%';
  }

  @override
  String get preparing => 'Preparando…';

  @override
  String get shuffleOn => 'Embaralhar: ativado';

  @override
  String get shuffle => 'Embaralhar';

  @override
  String get previous => 'Anterior';

  @override
  String get pause => 'Pausar';

  @override
  String get next => 'Próxima';

  @override
  String get repeatOff => 'Repetir: desativado';

  @override
  String get repeatAll => 'Repetir: toda a fila';

  @override
  String get repeatOne => 'Repetir: música atual';

  @override
  String get radioOn => 'Rádio: ativado';

  @override
  String get radioOff => 'Rádio: desativado';

  @override
  String get removeFromFavorites => 'Remover dos favoritos';

  @override
  String get addToFavorites => 'Adicionar aos favoritos';

  @override
  String get unmute => 'Ativar som';

  @override
  String get mute => 'Silenciar';

  @override
  String get unknownArtist => 'Artista desconhecido';

  @override
  String get minimize => 'Minimizar';

  @override
  String get restore => 'Restaurar';

  @override
  String get maximize => 'Maximizar';

  @override
  String get close => 'Fechar';

  @override
  String get noPlaylistsYet => 'Você ainda não tem playlists. Crie uma nova.';

  @override
  String get addedToPlaylist => 'Adicionada à playlist';

  @override
  String get playlistNamePrompt => 'Nome da playlist';

  @override
  String cantPlay(String error) {
    return 'Não foi possível reproduzir: $error';
  }

  @override
  String get language => 'Idioma';

  @override
  String get languageHint => 'O idioma da interface é salvo entre sessões';

  @override
  String get cache => 'Cache';

  @override
  String get cacheHint =>
      'As músicas baixadas são armazenadas localmente para reprodução mais rápida';

  @override
  String cacheUsed(String used, String limit) {
    return '$used de $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count arquivos',
      one: '1 arquivo',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Atualizar';

  @override
  String get clearCache => 'Limpar cache';

  @override
  String get confirmClearCacheTitle => 'Limpar cache';

  @override
  String get confirmClearCacheBody =>
      'Todas as músicas baixadas serão excluídas. Você precisará baixá-las novamente para reproduzi-las.';

  @override
  String get cacheCleared => 'Cache limpo';

  @override
  String get cantClearCache => 'Não foi possível limpar o cache';

  @override
  String get about => 'Sobre';

  @override
  String get version => 'Versão';

  @override
  String get discordPresence => 'Presença do Discord';

  @override
  String get discordPresenceHint =>
      'Mostra no seu perfil do Discord a música que você está ouvindo';

  @override
  String get discordEnabled => 'Ativar presença';

  @override
  String get discordClientId => 'ID do aplicativo';

  @override
  String get discordClientIdHint =>
      'Crie um app em discord.com/developers e cole aqui o ID do aplicativo';

  @override
  String get discordRequiresClientId =>
      'Você precisa criar um app no Portal de Desenvolvedores do Discord para a presença aparecer';
}
