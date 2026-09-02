// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get home => 'ホーム';

  @override
  String get library => 'ライブラリ';

  @override
  String get settings => '設定';

  @override
  String get backToPlaylists => 'プレイリストに戻る';

  @override
  String playbackErrorWithDetails(String details) {
    return '再生エラー: $details';
  }

  @override
  String get searchHint => 'YouTubeで曲を検索…';

  @override
  String get recentTitle => '最近再生した曲';

  @override
  String get recentPlaylistsTitle => 'Playlists recientes';

  @override
  String get addToPlaylist => 'プレイリストに追加';

  @override
  String get recentEmptyTitle => 'まだ何も再生していません';

  @override
  String get recentEmptyHint => '上の検索を使って始めましょう';

  @override
  String get backToHome => 'ホームに戻る';

  @override
  String get searchTitle => '検索';

  @override
  String get filterPlaylists => 'プレイリストを絞り込む…';

  @override
  String get searchStartHint => '曲を検索して再生を開始';

  @override
  String get searchNoResults => '結果がありません。別の検索をお試しください。';

  @override
  String get cantCreatePlaylist => 'プレイリストを作成できませんでした';

  @override
  String playlistCreated(String name) {
    return 'プレイリスト「$name」を作成しました';
  }

  @override
  String get deletePlaylistTitle => 'プレイリストを削除';

  @override
  String confirmDeletePlaylist(String name) {
    return '「$name」を削除しますか？';
  }

  @override
  String get confirmRemoveTrackTitle => 'プレイリストから削除しますか？';

  @override
  String confirmRemoveTrackBody(String name) {
    return '「$name」をこのプレイリストから削除します。';
  }

  @override
  String get cancel => 'キャンセル';

  @override
  String get delete => '削除';

  @override
  String get playlistDeleted => 'プレイリストを削除しました';

  @override
  String get playlistsTitle => 'プレイリスト';

  @override
  String get listViewTooltip => 'リスト表示';

  @override
  String get gridViewTooltip => 'グリッド表示';

  @override
  String get noPlaylists => 'プレイリストはまだありません';

  @override
  String get createOneHere => 'ここから作成';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count曲',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => '新しいプレイリスト';

  @override
  String get newPlaylistHint => '新しく作成';

  @override
  String get playlistName => '名前';

  @override
  String get playlistNameHint => 'マイプレイリスト';

  @override
  String get descriptionOptional => '説明（任意）';

  @override
  String get descriptionHint => 'このプレイリストについて';

  @override
  String get description => '説明';

  @override
  String get noCover => 'カバーなし';

  @override
  String get chooseImage => '画像を選択';

  @override
  String get changeImage => '変更';

  @override
  String get removeImage => '画像を削除';

  @override
  String get images => '画像';

  @override
  String get create => '作成';

  @override
  String get play => '再生';

  @override
  String get playShuffled => 'シャッフル再生';

  @override
  String get emptyPlaylist => '空のプレイリスト';

  @override
  String get emptyPlaylistHint => '検索から曲を追加してください';

  @override
  String get removeFromPlaylist => 'プレイリストから削除';

  @override
  String get changeCover => 'カバーを変更';

  @override
  String get editPlaylist => 'プレイリストを編集';

  @override
  String get edit => '編集';

  @override
  String get playlistUpdated => 'プレイリストを更新しました';

  @override
  String get cantSaveChanges => '変更を保存できませんでした';

  @override
  String get lessThanOneMinute => '1分未満';

  @override
  String durationMinutes(int m) {
    return '$m分';
  }

  @override
  String durationHours(int h) {
    return '$h時間';
  }

  @override
  String durationHoursMinutes(int h, int m) {
    return '$h時間$m分';
  }

  @override
  String playlistMeta(String songs, String duration) {
    return '$songs・$duration';
  }

  @override
  String get coverFromTrack => '曲からカバーを取得';

  @override
  String get coverFromTrackLabel => '曲のカバー';

  @override
  String get currentCover => '現在のカバー';

  @override
  String get removeCover => 'カバーを削除';

  @override
  String get save => '保存';

  @override
  String get nothingPlaying => '再生中はありません';

  @override
  String downloadingPercent(int percent) {
    return 'ダウンロード中… $percent%';
  }

  @override
  String get preparing => '準備中…';

  @override
  String get shuffleOn => 'シャッフル: オン';

  @override
  String get shuffle => 'シャッフル';

  @override
  String get playlistFilterHint => '曲を絞り込む';

  @override
  String get searchPlaylists => 'Buscar playlists';

  @override
  String get noMatchingPlaylists => 'Ninguna playlist coincide';

  @override
  String get playlistNoResults => '一致する曲がありません';

  @override
  String get previous => '前へ';

  @override
  String get pause => '一時停止';

  @override
  String get next => '次へ';

  @override
  String get repeatOff => 'リピート: オフ';

  @override
  String get repeatAll => 'リピート: 全曲';

  @override
  String get repeatOne => 'リピート: 1曲';

  @override
  String get radioOn => 'ラジオ: オン';

  @override
  String get radioOff => 'ラジオ: オフ';

  @override
  String get removeFromFavorites => 'お気に入りから削除';

  @override
  String get addToFavorites => 'お気に入りに追加';

  @override
  String get unmute => 'ミュート解除';

  @override
  String get mute => 'ミュート';

  @override
  String get unknownArtist => '不明なアーティスト';

  @override
  String get queue => 'キュー';

  @override
  String get queueTitle => '再生キュー';

  @override
  String get queueEmpty => 'キューは空です';

  @override
  String get queueEmptyHint => 'プレイリストや曲を再生するとここに表示されます';

  @override
  String get minimize => '最小化';

  @override
  String get restore => '元に戻す';

  @override
  String get maximize => '最大化';

  @override
  String get close => '閉じる';

  @override
  String get noPlaylistsYet => 'プレイリストはまだありません。新しいものを作成してください。';

  @override
  String get addedToPlaylist => 'プレイリストに追加しました';

  @override
  String get alreadyInPlaylist => 'このプレイリストにすでにあります';

  @override
  String get playerAnimation => 'プレイヤーのアニメーション';

  @override
  String get playerAnimationHint => 'プレイヤーのグラデーションと再生中バーのアニメーション';

  @override
  String get playerAnimationEnabled => 'アニメーションを使用';

  @override
  String get playlistNamePrompt => 'プレイリスト名';

  @override
  String cantPlay(String error) {
    return '再生できません: $error';
  }

  @override
  String get language => '言語';

  @override
  String get languageHint => 'インターフェース言語はセッション間で保存されます';

  @override
  String get cache => 'キャッシュ';

  @override
  String get cacheHint => 'ダウンロードした曲は高速再生のためにローカルに保存されます';

  @override
  String get paletteCacheTitle => 'アートワークの色';

  @override
  String get paletteCacheHint =>
      '各カバーはフルスクリーン背景用に3色を保存し、コントロールと歌詞のアクセントはそこから派生します。';

  @override
  String paletteCacheEntries(int n) {
    return 'キャッシュ済みカバー: $n';
  }

  @override
  String get paletteRecalc => '再計算';

  @override
  String get recalcColors => '色を再計算';

  @override
  String get colorsUpdated => '色を更新しました';

  @override
  String get playlistLabel => 'プレイリスト';

  @override
  String cacheUsed(String used, String limit) {
    return '$used / $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countファイル',
    );
    return '$_temp0';
  }

  @override
  String get refresh => '更新';

  @override
  String get clearCache => 'キャッシュをクリア';

  @override
  String get confirmClearCacheTitle => 'キャッシュをクリア';

  @override
  String get confirmClearCacheBody =>
      'ダウンロードした曲はすべて削除されます。再生するには再度ダウンロードが必要です。';

  @override
  String get cacheCleared => 'キャッシュをクリアしました';

  @override
  String get cantClearCache => 'キャッシュをクリアできませんでした';

  @override
  String get openFolder => 'フォルダを開く';

  @override
  String get cacheLimit => 'キャッシュの上限';

  @override
  String get cacheLimitHint => 'ダウンロード曲の最大ディスク使用量';

  @override
  String get about => '情報';

  @override
  String get version => 'バージョン';

  @override
  String get discordPresence => 'Discord プレゼンス';

  @override
  String get discordPresenceHint => 'Discordプロフィールに再生中の曲を表示します';

  @override
  String get discordEnabled => 'プレゼンスを有効にする';

  @override
  String get editMetadata => 'メタデータを編集';

  @override
  String get metadataTitle => 'タイトル';

  @override
  String get metadataArtist => 'アーティスト';

  @override
  String get metadataAlbum => 'アルバム';

  @override
  String get metadataCoverUrl => 'カバーURL';

  @override
  String get metadataSaved => 'メタデータを更新しました';

  @override
  String get metadataSearchDeezer => 'Deezerで検索';

  @override
  String get metadataNotFound => 'Deezerでメタデータが見つかりません';

  @override
  String get metadataCoverError => '画像をコピーできませんでした';

  @override
  String get metadataSearchOnline => 'オンラインで検索';

  @override
  String get metadataOnlineHint => 'タイトルとアーティスト（またはSpotifyのURL）';

  @override
  String get metadataNoResults => '結果なし';

  @override
  String get metadataApply => '適用';

  @override
  String get metadataSearchHint => 'Deezerはこのフォームのタイトルとアーティストで検索します';

  @override
  String get lyrics => '歌詞';

  @override
  String get lyricsTitle => '歌詞';

  @override
  String get syncLyrics => '同期';

  @override
  String get refreshLyrics => '歌詞を検索';

  @override
  String get lyricsNoTrack => '再生中の曲がありません';

  @override
  String get lyricsNotFound => '歌詞が見つかりません';

  @override
  String get lyricsNotFoundHint => 'メタデータ編集でアーティストまたはタイトルを修正してみてください';

  @override
  String get karaokeSweep => 'カラオケ';

  @override
  String get karaokeSweepHint => '曲に合わせて歌詞を単語ごとにハイライトします';

  @override
  String get done => '完了';

  @override
  String get importSpotify => 'プレイリストをインポート';

  @override
  String get spotifyUrlHint => 'Spotify・YouTubeのプレイリストリンク';

  @override
  String get importAction => 'インポート';

  @override
  String get spotifyFetchError => 'プレイリストを読み込めませんでした（リンクと公開設定を確認してください）';

  @override
  String get spotifyNoMatch => '一致なし';

  @override
  String spotifyTruncated(int limit) {
    return '大きなプレイリスト：Premiumなしでは最初の$limit曲のみインポートされます。';
  }

  @override
  String get karaokeSweepOn => 'カラオケ: オン';

  @override
  String get karaokeSweepOff => 'カラオケ: オフ';

  @override
  String get skipSilence => '無音をスキップ';

  @override
  String get skipSilenceHint => '再生中に音楽のない無音部分を自動的にスキップします';

  @override
  String get syncLyricsTitle => '歌詞の同期';

  @override
  String get syncCurrent => '現在';

  @override
  String get lyricsSearchNoResults => '結果が見つかりません';

  @override
  String get lyricsSearchError => '歌詞の検索中にエラー';

  @override
  String get lyricsSearchHint => '歌詞を検索 (タイトル アーティスト)';

  @override
  String get editLyrics => '歌詞を編集';

  @override
  String get useLyrics => '歌詞を使用';

  @override
  String get editLyricsHint => 'ここにLRCを貼り付け: 行ごとに [mm:ss.xx] テキスト';

  @override
  String get searchLyrics => '歌詞を検索';

  @override
  String get shareLyrics => '歌詞をシェア';

  @override
  String get saveAsImage => '画像として保存';

  @override
  String get copyText => 'コピー';

  @override
  String get imageCopied => '画像をクリップボードにコピーしました';

  @override
  String get imageSaved => '画像を保存しました';

  @override
  String shareOnSite(String site) {
    return '$siteでシェア';
  }

  @override
  String lineOfTotal(int index, int total) {
    return '$total件中$index件目';
  }

  @override
  String get audioOutput => '音声出力';

  @override
  String get keyboardShortcuts => 'キーボードショートカット';

  @override
  String get shortcutPlayPause => '再生 / 一時停止';

  @override
  String get shortcutNext => '次の曲';

  @override
  String get shortcutPrevious => '前の曲';

  @override
  String get shortcutSeekForward => '10秒早送り';

  @override
  String get shortcutSeekBackward => '10秒巻き戻し';

  @override
  String get shortcutVolumeUp => '音量 +5%';

  @override
  String get shortcutVolumeDown => '音量 -5%';

  @override
  String get shortcutMute => 'ミュート / ミュート解除';

  @override
  String get shortcutToggleLyrics => '歌詞の表示切替';

  @override
  String get shortcutToggleQueue => 'キューの表示切替';

  @override
  String get shortcutToggleSettings => '設定の表示切替';

  @override
  String get shortcutClosePanel => 'アクティブパネルを閉じる';

  @override
  String get shortcutFullscreen => 'フルスクリーン';

  @override
  String get shortcutToggleShuffle => 'シャッフル切替';

  @override
  String get shortcutToggleRepeat => 'リピート切替';

  @override
  String get shortcutToggleRadio => 'ラジオモード切替';

  @override
  String get shortcutToggleFavorite => 'お気に入りに追加 / 削除';

  @override
  String get shortcutCategoryPlayback => '再生';

  @override
  String get shortcutCategoryVolume => '音量';

  @override
  String get shortcutCategoryNavigation => 'ナビゲーション';

  @override
  String get shortcutCategoryModes => 'モード';

  @override
  String get shortcutMouseBack => '前の曲 (マウス)';

  @override
  String get shortcutMouseForward => '次の曲 (マウス)';

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
