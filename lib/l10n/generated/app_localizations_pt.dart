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
  String get filterPlaylists => 'Filtrar playlists…';

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
  String get confirmRemoveTrackTitle => 'Remover da playlist?';

  @override
  String confirmRemoveTrackBody(String name) {
    return '\"$name\" será removida desta playlist.';
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
  String get playlistFilterHint => 'Filtrar músicas';

  @override
  String get playlistNoResults => 'Nenhuma música corresponde';

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
  String get queue => 'Fila';

  @override
  String get queueTitle => 'Fila de reprodução';

  @override
  String get queueEmpty => 'A fila está vazia';

  @override
  String get queueEmptyHint =>
      'Reproduza uma playlist ou música para vê-la aqui';

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
  String get alreadyInPlaylist => 'Já está nesta playlist';

  @override
  String get playerAnimation => 'Animação do player';

  @override
  String get playerAnimationHint =>
      'Gradiente animado no player e as barras em reprodução';

  @override
  String get playerAnimationEnabled => 'Usar animação';

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
  String get paletteCacheTitle => 'Cores das capas';

  @override
  String get paletteCacheHint =>
      'Cada capa guarda 3 cores para o fundo em tela cheia; o acento dos controles e letras é derivado delas.';

  @override
  String paletteCacheEntries(int n) {
    return 'Capas em cache: $n';
  }

  @override
  String get paletteRecalc => 'Recalcular';

  @override
  String get recalcColors => 'Recalcular cores';

  @override
  String get colorsUpdated => 'Cores atualizados';

  @override
  String get playlistLabel => 'Playlist';

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
  String get openFolder => 'Abrir pasta';

  @override
  String get cacheLimit => 'Limite da cache';

  @override
  String get cacheLimitHint => 'Espaço máximo em disco para músicas baixadas';

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
  String get editMetadata => 'Editar metadados';

  @override
  String get metadataTitle => 'Título';

  @override
  String get metadataArtist => 'Artista';

  @override
  String get metadataAlbum => 'Álbum';

  @override
  String get metadataCoverUrl => 'URL da capa';

  @override
  String get metadataSaved => 'Metadados atualizados';

  @override
  String get metadataSearchDeezer => 'Pesquisar no Deezer';

  @override
  String get metadataNotFound => 'Metadados não encontrados no Deezer';

  @override
  String get metadataCoverError => 'Não foi possível copiar a imagem';

  @override
  String get metadataSearchOnline => 'Pesquisar online';

  @override
  String get metadataOnlineHint =>
      'Título e artista (ou cole um URL do Spotify)';

  @override
  String get metadataNoResults => 'Sem resultados';

  @override
  String get metadataApply => 'Aplicar';

  @override
  String get metadataSearchHint =>
      'O Deezer pesquisará com o título e artista deste formulário';

  @override
  String get lyrics => 'Letra';

  @override
  String get lyricsTitle => 'Letra';

  @override
  String get syncLyrics => 'Sincronizar';

  @override
  String get refreshLyrics => 'Pesquisar letra';

  @override
  String get lyricsNoTrack => 'Sem reprodução';

  @override
  String get lyricsNotFound => 'Letra não encontrada';

  @override
  String get lyricsNotFoundHint =>
      'Tente corrigir o artista ou o título em Editar metadados';

  @override
  String get karaokeSweep => 'Karaoke';

  @override
  String get karaokeSweepHint =>
      'Realça a letra palavra a palavra ao ritmo da música';

  @override
  String get done => 'Concluído';

  @override
  String get importSpotify => 'Importar playlist';

  @override
  String get spotifyUrlHint => 'Link da playlist do Spotify ou YouTube';

  @override
  String get importAction => 'Importar';

  @override
  String get spotifyFetchError =>
      'Não foi possível ler a playlist (o link está correto e é pública?)';

  @override
  String get spotifyNoMatch => 'Sem correspondência';

  @override
  String spotifyTruncated(int limit) {
    return 'Playlist grande: sem o Spotify Premium apenas as primeiras $limit faixas são importadas.';
  }

  @override
  String get karaokeSweepOn => 'Karaoke: ativo';

  @override
  String get karaokeSweepOff => 'Karaoke: inativo';

  @override
  String get skipSilence => 'Ignorar silêncios';

  @override
  String get skipSilenceHint =>
      'Avança automaticamente as partes sem música durante a reprodução';

  @override
  String get syncLyricsTitle => 'Sincronização da letra';

  @override
  String get syncCurrent => 'Atual';

  @override
  String get lyricsSearchNoResults => 'Nenhum resultado encontrado';

  @override
  String get lyricsSearchError => 'Erro ao pesquisar a letra';

  @override
  String get lyricsSearchHint => 'Pesquisar letra (título artista)';

  @override
  String get editLyrics => 'Editar letra';

  @override
  String get useLyrics => 'Usar letra';

  @override
  String get editLyricsHint => 'Cole o LRC aqui: [mm:ss.xx] texto por linha';

  @override
  String get searchLyrics => 'Pesquisar letra';

  @override
  String get shareLyrics => 'Partilhar letra';

  @override
  String get saveAsImage => 'Guardar imagem';

  @override
  String get copyText => 'Copiar';

  @override
  String get imageCopied => 'Imagem copiada para a área de transferência';

  @override
  String get imageSaved => 'Imagem guardada';

  @override
  String shareOnSite(String site) {
    return 'Partilhar no $site';
  }

  @override
  String lineOfTotal(int index, int total) {
    return '$index de $total';
  }

  @override
  String get audioOutput => 'Saída de áudio';

  @override
  String get keyboardShortcuts => 'Atalhos de teclado';

  @override
  String get shortcutPlayPause => 'Reproduzir / Pausar';

  @override
  String get shortcutNext => 'Próxima música';

  @override
  String get shortcutPrevious => 'Música anterior';

  @override
  String get shortcutSeekForward => 'Avançar 10s';

  @override
  String get shortcutSeekBackward => 'Retroceder 10s';

  @override
  String get shortcutVolumeUp => 'Aumentar volume 5%';

  @override
  String get shortcutVolumeDown => 'Diminuir volume 5%';

  @override
  String get shortcutMute => 'Silenciar / Restaurar som';

  @override
  String get shortcutToggleLyrics => 'Mostrar / ocultar letras';

  @override
  String get shortcutToggleQueue => 'Mostrar / ocultar fila';

  @override
  String get shortcutToggleSettings => 'Mostrar / ocultar configurações';

  @override
  String get shortcutClosePanel => 'Fechar painel ativo';

  @override
  String get shortcutFullscreen => 'Ecrã inteiro';

  @override
  String get shortcutToggleShuffle => 'Alternar modo aleatório';

  @override
  String get shortcutToggleRepeat => 'Alternar repetição';

  @override
  String get shortcutToggleRadio => 'Alternar modo rádio';

  @override
  String get shortcutToggleFavorite => 'Adicionar / remover dos favoritos';

  @override
  String get shortcutCategoryPlayback => 'Reprodução';

  @override
  String get shortcutCategoryVolume => 'Volume';

  @override
  String get shortcutCategoryNavigation => 'Navegação';

  @override
  String get shortcutCategoryModes => 'Modos';

  @override
  String get shortcutMouseBack => 'Música anterior (rato)';

  @override
  String get shortcutMouseForward => 'Próxima música (rato)';

  @override
  String get provider => 'Proveedor:';

  @override
  String get providerAll => 'Todos (KPoe + Unison + LRCLIB)';

  @override
  String get providerKpoe => 'KPoe · palabra a palabra';

  @override
  String get providerUnison => 'Unison';

  @override
  String get providerLrclib => 'LRCLIB · línea';
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
  String get filterPlaylists => 'Filtrar playlists…';

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
  String get confirmRemoveTrackTitle => 'Remover da playlist?';

  @override
  String confirmRemoveTrackBody(String name) {
    return '\"$name\" será removida desta playlist.';
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
  String get playlistFilterHint => 'Filtrar músicas';

  @override
  String get playlistNoResults => 'Nenhuma música corresponde';

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
  String get queue => 'Fila';

  @override
  String get queueTitle => 'Fila de reprodução';

  @override
  String get queueEmpty => 'A fila está vazia';

  @override
  String get queueEmptyHint =>
      'Reproduza uma playlist ou música para vê-la aqui';

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
  String get alreadyInPlaylist => 'Já está nesta playlist';

  @override
  String get playerAnimation => 'Animação do player';

  @override
  String get playerAnimationHint =>
      'Gradiente animado no player e as barras em reprodução';

  @override
  String get playerAnimationEnabled => 'Usar animação';

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
  String get paletteCacheTitle => 'Cores das capas';

  @override
  String get paletteCacheHint =>
      'Cada capa guarda 3 cores para o fundo em tela cheia; o acento dos controles e letras é derivado delas.';

  @override
  String paletteCacheEntries(int n) {
    return 'Capas em cache: $n';
  }

  @override
  String get paletteRecalc => 'Recalcular';

  @override
  String get recalcColors => 'Recalcular cores';

  @override
  String get colorsUpdated => 'Cores atualizados';

  @override
  String get playlistLabel => 'Playlist';

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
  String get openFolder => 'Abrir pasta';

  @override
  String get cacheLimit => 'Limite da cache';

  @override
  String get cacheLimitHint => 'Espaço máximo em disco para músicas baixadas';

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
  String get editMetadata => 'Editar metadados';

  @override
  String get metadataTitle => 'Título';

  @override
  String get metadataArtist => 'Artista';

  @override
  String get metadataAlbum => 'Álbum';

  @override
  String get metadataCoverUrl => 'URL da capa';

  @override
  String get metadataSaved => 'Metadados atualizados';

  @override
  String get metadataSearchDeezer => 'Pesquisar no Deezer';

  @override
  String get metadataNotFound => 'Metadados não encontrados no Deezer';

  @override
  String get metadataCoverError => 'Não foi possível copiar a imagem';

  @override
  String get metadataSearchOnline => 'Pesquisar on-line';

  @override
  String get metadataOnlineHint =>
      'Título e artista (ou cole um URL do Spotify)';

  @override
  String get metadataNoResults => 'Sem resultados';

  @override
  String get metadataApply => 'Aplicar';

  @override
  String get metadataSearchHint =>
      'O Deezer pesquisará com o título e artista deste formulário';

  @override
  String get lyrics => 'Letra';

  @override
  String get lyricsTitle => 'Letra';

  @override
  String get syncLyrics => 'Sincronizar';

  @override
  String get refreshLyrics => 'Pesquisar letra';

  @override
  String get lyricsNoTrack => 'Sem reprodução';

  @override
  String get lyricsNotFound => 'Letra não encontrada';

  @override
  String get lyricsNotFoundHint =>
      'Tente corrigir o artista ou o título em Editar metadados';

  @override
  String get karaokeSweep => 'Karaokê';

  @override
  String get karaokeSweepHint =>
      'Realça a letra palavra a palavra ao ritmo da música';

  @override
  String get done => 'Concluído';

  @override
  String get importSpotify => 'Importar playlist';

  @override
  String get spotifyUrlHint => 'Link da playlist do Spotify ou YouTube';

  @override
  String get importAction => 'Importar';

  @override
  String get spotifyFetchError =>
      'Não foi possível ler a playlist (o link está correto e ela é pública?)';

  @override
  String get spotifyNoMatch => 'Sem correspondência';

  @override
  String spotifyTruncated(int limit) {
    return 'Playlist grande: sem o Spotify Premium apenas as primeiras $limit faixas são importadas.';
  }

  @override
  String get karaokeSweepOn => 'Karaokê: ativo';

  @override
  String get karaokeSweepOff => 'Karaokê: inativo';

  @override
  String get skipSilence => 'Pular silêncios';

  @override
  String get skipSilenceHint =>
      'Avança automaticamente as partes sem música durante a reprodução';

  @override
  String get syncLyricsTitle => 'Sincronização da letra';

  @override
  String get syncCurrent => 'Atual';

  @override
  String get lyricsSearchNoResults => 'Nenhum resultado encontrado';

  @override
  String get lyricsSearchError => 'Erro ao pesquisar a letra';

  @override
  String get lyricsSearchHint => 'Pesquisar letra (título artista)';

  @override
  String get editLyrics => 'Editar letra';

  @override
  String get useLyrics => 'Usar letra';

  @override
  String get editLyricsHint => 'Cole o LRC aqui: [mm:ss.xx] texto por linha';

  @override
  String get searchLyrics => 'Pesquisar letra';

  @override
  String get shareLyrics => 'Compartilhar letra';

  @override
  String get saveAsImage => 'Salvar imagem';

  @override
  String get copyText => 'Copiar';

  @override
  String get imageCopied => 'Imagem copiada para a área de transferência';

  @override
  String get imageSaved => 'Imagem salva';

  @override
  String shareOnSite(String site) {
    return 'Compartilhar no $site';
  }

  @override
  String lineOfTotal(int index, int total) {
    return '$index de $total';
  }

  @override
  String get audioOutput => 'Saída de áudio';

  @override
  String get keyboardShortcuts => 'Atalhos de teclado';

  @override
  String get shortcutPlayPause => 'Reproduzir / Pausar';

  @override
  String get shortcutNext => 'Próxima música';

  @override
  String get shortcutPrevious => 'Música anterior';

  @override
  String get shortcutSeekForward => 'Avançar 10s';

  @override
  String get shortcutSeekBackward => 'Retroceder 10s';

  @override
  String get shortcutVolumeUp => 'Aumentar volume 5%';

  @override
  String get shortcutVolumeDown => 'Diminuir volume 5%';

  @override
  String get shortcutMute => 'Silenciar / Restaurar som';

  @override
  String get shortcutToggleLyrics => 'Mostrar / ocultar letras';

  @override
  String get shortcutToggleQueue => 'Mostrar / ocultar fila';

  @override
  String get shortcutToggleSettings => 'Mostrar / ocultar configurações';

  @override
  String get shortcutClosePanel => 'Fechar painel ativo';

  @override
  String get shortcutFullscreen => 'Tela cheia';

  @override
  String get shortcutToggleShuffle => 'Alternar modo aleatório';

  @override
  String get shortcutToggleRepeat => 'Alternar repetição';

  @override
  String get shortcutToggleRadio => 'Alternar modo rádio';

  @override
  String get shortcutToggleFavorite => 'Adicionar / remover dos favoritos';

  @override
  String get shortcutCategoryPlayback => 'Reprodução';

  @override
  String get shortcutCategoryVolume => 'Volume';

  @override
  String get shortcutCategoryNavigation => 'Navegação';

  @override
  String get shortcutCategoryModes => 'Modos';

  @override
  String get shortcutMouseBack => 'Música anterior (mouse)';

  @override
  String get shortcutMouseForward => 'Próxima música (mouse)';
}
