// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get settings => '设置';

  @override
  String get backToPlaylists => '返回播放列表';

  @override
  String playbackErrorWithDetails(String details) {
    return '播放错误：$details';
  }

  @override
  String get searchHint => '在 YouTube 上搜索歌曲…';

  @override
  String get recentTitle => '最近播放';

  @override
  String get addToPlaylist => '添加到播放列表';

  @override
  String get recentEmptyTitle => '还没有播放任何内容';

  @override
  String get recentEmptyHint => '使用上方搜索开始吧';

  @override
  String get backToHome => '返回首页';

  @override
  String get searchTitle => '搜索';

  @override
  String get filterPlaylists => '筛选播放列表…';

  @override
  String get searchStartHint => '搜索歌曲开始播放';

  @override
  String get searchNoResults => '没有结果。请尝试其他搜索。';

  @override
  String get cantCreatePlaylist => '无法创建播放列表';

  @override
  String playlistCreated(String name) {
    return '播放列表“$name”已创建';
  }

  @override
  String get deletePlaylistTitle => '删除播放列表';

  @override
  String confirmDeletePlaylist(String name) {
    return '删除“$name”？';
  }

  @override
  String get confirmRemoveTrackTitle => '从播放列表中移除？';

  @override
  String confirmRemoveTrackBody(String name) {
    return '将从该播放列表中移除“$name”。';
  }

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get playlistDeleted => '播放列表已删除';

  @override
  String get playlistsTitle => '播放列表';

  @override
  String get listViewTooltip => '列表视图';

  @override
  String get gridViewTooltip => '网格视图';

  @override
  String get noPlaylists => '还没有播放列表';

  @override
  String get createOneHere => '在这里创建';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 首歌曲',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => '新建播放列表';

  @override
  String get newPlaylistHint => '创建一个新的';

  @override
  String get playlistName => '名称';

  @override
  String get playlistNameHint => '我的播放列表';

  @override
  String get descriptionOptional => '描述（可选）';

  @override
  String get descriptionHint => '这个播放列表是关于什么的？';

  @override
  String get description => '描述';

  @override
  String get noCover => '无封面';

  @override
  String get chooseImage => '选择图片';

  @override
  String get changeImage => '更改';

  @override
  String get removeImage => '移除图片';

  @override
  String get images => '图片';

  @override
  String get create => '创建';

  @override
  String get play => '播放';

  @override
  String get playShuffled => '随机播放';

  @override
  String get emptyPlaylist => '空播放列表';

  @override
  String get emptyPlaylistHint => '从搜索中添加歌曲';

  @override
  String get removeFromPlaylist => '从播放列表中移除';

  @override
  String get editPlaylist => '编辑播放列表';

  @override
  String get edit => '编辑';

  @override
  String get playlistUpdated => '播放列表已更新';

  @override
  String get cantSaveChanges => '无法保存更改';

  @override
  String get lessThanOneMinute => '不到 1 分钟';

  @override
  String durationMinutes(int m) {
    return '$m 分钟';
  }

  @override
  String durationHours(int h) {
    return '$h 小时';
  }

  @override
  String durationHoursMinutes(int h, int m) {
    return '$h 小时 $m 分钟';
  }

  @override
  String playlistMeta(String songs, String duration) {
    return '$songs · $duration';
  }

  @override
  String get coverFromTrack => '从歌曲获取封面';

  @override
  String get coverFromTrackLabel => '歌曲封面';

  @override
  String get currentCover => '当前封面';

  @override
  String get removeCover => '移除封面';

  @override
  String get save => '保存';

  @override
  String get nothingPlaying => '没有正在播放';

  @override
  String downloadingPercent(int percent) {
    return '下载中… $percent%';
  }

  @override
  String get preparing => '准备中…';

  @override
  String get shuffleOn => '随机播放：已开启';

  @override
  String get shuffle => '随机播放';

  @override
  String get playlistFilterHint => '筛选歌曲';

  @override
  String get playlistNoResults => '没有匹配的歌曲';

  @override
  String get previous => '上一首';

  @override
  String get pause => '暂停';

  @override
  String get next => '下一首';

  @override
  String get repeatOff => '重复：已关闭';

  @override
  String get repeatAll => '重复：全部队列';

  @override
  String get repeatOne => '重复：当前歌曲';

  @override
  String get radioOn => '电台：已开启';

  @override
  String get radioOff => '电台：已关闭';

  @override
  String get removeFromFavorites => '从收藏中移除';

  @override
  String get addToFavorites => '添加到收藏';

  @override
  String get unmute => '取消静音';

  @override
  String get mute => '静音';

  @override
  String get unknownArtist => '未知艺术家';

  @override
  String get queue => '播放队列';

  @override
  String get queueTitle => '播放队列';

  @override
  String get queueEmpty => '队列为空';

  @override
  String get queueEmptyHint => '播放播放列表或歌曲后会显示在这里';

  @override
  String get minimize => '最小化';

  @override
  String get restore => '还原';

  @override
  String get maximize => '最大化';

  @override
  String get close => '关闭';

  @override
  String get noPlaylistsYet => '还没有播放列表。请创建一个新的。';

  @override
  String get addedToPlaylist => '已添加到播放列表';

  @override
  String get alreadyInPlaylist => '已在此播放列表中';

  @override
  String get playerAnimation => '播放器动画';

  @override
  String get playerAnimationHint => '播放器渐变和播放中指示条的动画';

  @override
  String get playerAnimationEnabled => '使用动画';

  @override
  String get playlistNamePrompt => '播放列表名称';

  @override
  String cantPlay(String error) {
    return '无法播放：$error';
  }

  @override
  String get language => '语言';

  @override
  String get languageHint => '界面语言会在会话之间保存';

  @override
  String get cache => '缓存';

  @override
  String get cacheHint => '已下载的歌曲会保存在本地，以便更快播放';

  @override
  String get paletteCacheTitle => '封面颜色';

  @override
  String get paletteCacheHint => '每张封面存储 3 种颜色用于全屏背景；控件和歌词的强调色由它们派生。';

  @override
  String paletteCacheEntries(int n) {
    return '已缓存封面：$n';
  }

  @override
  String get paletteRecalc => '重新计算';

  @override
  String get recalcColors => '重新计算颜色';

  @override
  String get colorsUpdated => '颜色已更新';

  @override
  String get playlistLabel => '播放列表';

  @override
  String cacheUsed(String used, String limit) {
    return '$used / $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
    );
    return '$_temp0';
  }

  @override
  String get refresh => '刷新';

  @override
  String get clearCache => '清除缓存';

  @override
  String get confirmClearCacheTitle => '清除缓存';

  @override
  String get confirmClearCacheBody => '所有已下载的歌曲都将被删除。再次播放需要重新下载。';

  @override
  String get cacheCleared => '缓存已清除';

  @override
  String get cantClearCache => '无法清除缓存';

  @override
  String get openFolder => '打开文件夹';

  @override
  String get cacheLimit => '缓存上限';

  @override
  String get cacheLimitHint => '已下载歌曲的最大磁盘使用量';

  @override
  String get about => '关于';

  @override
  String get version => '版本';

  @override
  String get discordPresence => 'Discord 状态';

  @override
  String get discordPresenceHint => '在您的 Discord 个人资料中显示正在播放的歌曲';

  @override
  String get discordEnabled => '启用状态显示';

  @override
  String get editMetadata => '编辑元数据';

  @override
  String get metadataTitle => '标题';

  @override
  String get metadataArtist => '艺术家';

  @override
  String get metadataAlbum => '专辑';

  @override
  String get metadataCoverUrl => '封面 URL';

  @override
  String get metadataSaved => '元数据已更新';

  @override
  String get metadataSearchDeezer => '在 Deezer 上搜索';

  @override
  String get metadataNotFound => '未在 Deezer 上找到元数据';

  @override
  String get metadataCoverError => '无法复制图片';

  @override
  String get metadataSearchOnline => '在线搜索';

  @override
  String get metadataOnlineHint => '标题和艺术家（或粘贴 Spotify 链接）';

  @override
  String get metadataNoResults => '无结果';

  @override
  String get metadataApply => '应用';

  @override
  String get metadataSearchHint => 'Deezer 将使用此表单中的标题和艺术家进行搜索';

  @override
  String get lyrics => '歌词';

  @override
  String get lyricsTitle => '歌词';

  @override
  String get syncLyrics => '同步';

  @override
  String get refreshLyrics => '搜索歌词';

  @override
  String get lyricsNoTrack => '没有正在播放的歌曲';

  @override
  String get lyricsNotFound => '未找到歌词';

  @override
  String get lyricsNotFoundHint => '尝试在编辑元数据中修正艺术家或标题';

  @override
  String get karaokeSweep => '卡拉OK';

  @override
  String get karaokeSweepHint => '随歌曲逐词高亮歌词';

  @override
  String get done => '完成';

  @override
  String get importSpotify => '导入播放列表';

  @override
  String get spotifyUrlHint => 'Spotify 或 YouTube 播放列表链接';

  @override
  String get importAction => '导入';

  @override
  String get spotifyFetchError => '无法读取播放列表（请检查链接是否正确且公开）';

  @override
  String get spotifyNoMatch => '无匹配';

  @override
  String spotifyTruncated(int limit) {
    return '大播放列表：无 Premium 仅导入前 $limit 首。';
  }

  @override
  String get karaokeSweepOn => '卡拉OK：开启';

  @override
  String get karaokeSweepOff => '卡拉OK：关闭';

  @override
  String get skipSilence => '跳过静音';

  @override
  String get skipSilenceHint => '播放时自动跳过没有音乐的静音片段';

  @override
  String get syncLyricsTitle => '歌词同步';

  @override
  String get syncCurrent => '当前';

  @override
  String get lyricsSearchNoResults => '未找到结果';

  @override
  String get lyricsSearchError => '搜索歌词时出错';

  @override
  String get lyricsSearchHint => '搜索歌词（标题 艺术家）';

  @override
  String get editLyrics => '编辑歌词';

  @override
  String get useLyrics => '使用歌词';

  @override
  String get editLyricsHint => '在此粘贴 LRC：每行 [mm:ss.xx] 文本';

  @override
  String get searchLyrics => '搜索歌词';

  @override
  String get shareLyrics => '分享歌词';

  @override
  String get saveAsImage => '保存为图片';

  @override
  String get copyText => '复制';

  @override
  String get imageCopied => '图片已复制到剪贴板';

  @override
  String get imageSaved => '图片已保存';

  @override
  String shareOnSite(String site) {
    return '分享到 $site';
  }

  @override
  String lineOfTotal(int index, int total) {
    return '第 $index/$total 句';
  }

  @override
  String get audioOutput => '音频输出';

  @override
  String get keyboardShortcuts => '键盘快捷键';

  @override
  String get shortcutPlayPause => '播放 / 暂停';

  @override
  String get shortcutNext => '下一首';

  @override
  String get shortcutPrevious => '上一首';

  @override
  String get shortcutSeekForward => '快进 10 秒';

  @override
  String get shortcutSeekBackward => '快退 10 秒';

  @override
  String get shortcutVolumeUp => '音量 +5%';

  @override
  String get shortcutVolumeDown => '音量 -5%';

  @override
  String get shortcutMute => '静音 / 取消静音';

  @override
  String get shortcutToggleLyrics => '切换歌词显示';

  @override
  String get shortcutToggleQueue => '切换播放队列';

  @override
  String get shortcutToggleSettings => '切换设置';

  @override
  String get shortcutClosePanel => '关闭当前面板';

  @override
  String get shortcutFullscreen => '全屏';

  @override
  String get shortcutToggleShuffle => '切换随机播放';

  @override
  String get shortcutToggleRepeat => '切换循环模式';

  @override
  String get shortcutToggleRadio => '切换电台模式';

  @override
  String get shortcutToggleFavorite => '添加 / 移除收藏';

  @override
  String get shortcutCategoryPlayback => '播放';

  @override
  String get shortcutCategoryVolume => '音量';

  @override
  String get shortcutCategoryNavigation => '导航';

  @override
  String get shortcutCategoryModes => '模式';
}
