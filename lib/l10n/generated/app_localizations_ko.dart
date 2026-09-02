// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'Scrup';

  @override
  String get home => '홈';

  @override
  String get library => '라이브러리';

  @override
  String get settings => '설정';

  @override
  String get backToPlaylists => '플레이리스트로 돌아가기';

  @override
  String playbackErrorWithDetails(String details) {
    return '재생 오류: $details';
  }

  @override
  String get searchHint => 'YouTube에서 노래 검색…';

  @override
  String get recentTitle => '최근 재생';

  @override
  String get addToPlaylist => '플레이리스트에 추가';

  @override
  String get recentEmptyTitle => '아직 재생한 곡이 없습니다';

  @override
  String get recentEmptyHint => '위의 검색을 사용해 시작하세요';

  @override
  String get backToHome => '홈으로 돌아가기';

  @override
  String get searchTitle => '검색';

  @override
  String get filterPlaylists => '플레이리스트 필터…';

  @override
  String get searchStartHint => '재생할 노래를 검색하세요';

  @override
  String get searchNoResults => '결과가 없습니다. 다른 검색을 시도하세요.';

  @override
  String get cantCreatePlaylist => '플레이리스트를 만들 수 없습니다';

  @override
  String playlistCreated(String name) {
    return '플레이리스트 \"$name\" 생성됨';
  }

  @override
  String get deletePlaylistTitle => '플레이리스트 삭제';

  @override
  String confirmDeletePlaylist(String name) {
    return '\"$name\"을(를) 삭제할까요?';
  }

  @override
  String get confirmRemoveTrackTitle => '플레이리스트에서 제거할까요?';

  @override
  String confirmRemoveTrackBody(String name) {
    return '\"$name\"을(를) 이 플레이리스트에서 제거합니다.';
  }

  @override
  String get cancel => '취소';

  @override
  String get delete => '삭제';

  @override
  String get playlistDeleted => '플레이리스트 삭제됨';

  @override
  String get playlistsTitle => '플레이리스트';

  @override
  String get listViewTooltip => '목록 보기';

  @override
  String get gridViewTooltip => '그리드 보기';

  @override
  String get noPlaylists => '아직 플레이리스트가 없습니다';

  @override
  String get createOneHere => '여기에서 만들기';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '노래 $count곡',
    );
    return '$_temp0';
  }

  @override
  String get newPlaylist => '새 플레이리스트';

  @override
  String get newPlaylistHint => '새로 만들기';

  @override
  String get playlistName => '이름';

  @override
  String get playlistNameHint => '내 플레이리스트';

  @override
  String get descriptionOptional => '설명 (선택 사항)';

  @override
  String get descriptionHint => '이 플레이리스트는 어떤 내용인가요?';

  @override
  String get description => '설명';

  @override
  String get noCover => '커버 없음';

  @override
  String get chooseImage => '이미지 선택';

  @override
  String get changeImage => '변경';

  @override
  String get removeImage => '이미지 제거';

  @override
  String get images => '이미지';

  @override
  String get create => '만들기';

  @override
  String get play => '재생';

  @override
  String get playShuffled => '셔플 재생';

  @override
  String get emptyPlaylist => '빈 플레이리스트';

  @override
  String get emptyPlaylistHint => '검색에서 노래를 추가하세요';

  @override
  String get removeFromPlaylist => '플레이리스트에서 제거';

  @override
  String get changeCover => '커버 변경';

  @override
  String get editPlaylist => '플레이리스트 편집';

  @override
  String get edit => '편집';

  @override
  String get playlistUpdated => '플레이리스트 업데이트됨';

  @override
  String get cantSaveChanges => '변경 사항을 저장할 수 없습니다';

  @override
  String get lessThanOneMinute => '1분 미만';

  @override
  String durationMinutes(int m) {
    return '$m분';
  }

  @override
  String durationHours(int h) {
    return '$h시간';
  }

  @override
  String durationHoursMinutes(int h, int m) {
    return '$h시간 $m분';
  }

  @override
  String playlistMeta(String songs, String duration) {
    return '$songs · $duration';
  }

  @override
  String get coverFromTrack => '노래에서 커버 가져오기';

  @override
  String get coverFromTrackLabel => '노래 커버';

  @override
  String get currentCover => '현재 커버';

  @override
  String get removeCover => '커버 제거';

  @override
  String get save => '저장';

  @override
  String get nothingPlaying => '재생 중인 곡 없음';

  @override
  String downloadingPercent(int percent) {
    return '다운로드 중… $percent%';
  }

  @override
  String get preparing => '준비 중…';

  @override
  String get shuffleOn => '셔플: 켜짐';

  @override
  String get shuffle => '셔플';

  @override
  String get playlistFilterHint => '곡 필터링';

  @override
  String get playlistNoResults => '일치하는 곡이 없습니다';

  @override
  String get previous => '이전';

  @override
  String get pause => '일시 정지';

  @override
  String get next => '다음';

  @override
  String get repeatOff => '반복: 꺼짐';

  @override
  String get repeatAll => '반복: 전체 재생목록';

  @override
  String get repeatOne => '반복: 현재 곡';

  @override
  String get radioOn => '라디오: 켜짐';

  @override
  String get radioOff => '라디오: 꺼짐';

  @override
  String get removeFromFavorites => '즐겨찾기에서 제거';

  @override
  String get addToFavorites => '즐겨찾기에 추가';

  @override
  String get unmute => '음소거 해제';

  @override
  String get mute => '음소거';

  @override
  String get unknownArtist => '알 수 없는 아티스트';

  @override
  String get queue => '대기열';

  @override
  String get queueTitle => '재생 대기열';

  @override
  String get queueEmpty => '대기열이 비어 있습니다';

  @override
  String get queueEmptyHint => '플레이리스트나 노래를 재생하면 여기에 표시됩니다';

  @override
  String get minimize => '최소화';

  @override
  String get restore => '복원';

  @override
  String get maximize => '최대화';

  @override
  String get close => '닫기';

  @override
  String get noPlaylistsYet => '아직 플레이리스트가 없습니다. 새로 만드세요.';

  @override
  String get addedToPlaylist => '플레이리스트에 추가됨';

  @override
  String get alreadyInPlaylist => '이미 이 플레이리스트에 있습니다';

  @override
  String get playerAnimation => '플레이어 애니메이션';

  @override
  String get playerAnimationHint => '플레이어의 그라데이션과 재생 중 막대 애니메이션';

  @override
  String get playerAnimationEnabled => '애니메이션 사용';

  @override
  String get playlistNamePrompt => '플레이리스트 이름';

  @override
  String cantPlay(String error) {
    return '재생할 수 없습니다: $error';
  }

  @override
  String get language => '언어';

  @override
  String get languageHint => '인터페이스 언어는 세션 간에 저장됩니다';

  @override
  String get cache => '캐시';

  @override
  String get cacheHint => '다운로드한 노래는 더 빠른 재생을 위해 로컬에 저장됩니다';

  @override
  String get paletteCacheTitle => '아트워크 색상';

  @override
  String get paletteCacheHint =>
      '각 커버는 전체 화면 배경에 3색을 저장하며, 컨트롤과 가사의 강조색은 여기서 파생됩니다.';

  @override
  String paletteCacheEntries(int n) {
    return '캐시된 커버: $n';
  }

  @override
  String get paletteRecalc => '재계산';

  @override
  String get recalcColors => '색상 재계산';

  @override
  String get colorsUpdated => '색상이 업데이트되었습니다';

  @override
  String get playlistLabel => '재생목록';

  @override
  String cacheUsed(String used, String limit) {
    return '$used / $limit';
  }

  @override
  String cacheFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '파일 $count개',
    );
    return '$_temp0';
  }

  @override
  String get refresh => '새로 고침';

  @override
  String get clearCache => '캐시 지우기';

  @override
  String get confirmClearCacheTitle => '캐시 지우기';

  @override
  String get confirmClearCacheBody =>
      '다운로드한 모든 노래가 삭제됩니다. 재생하려면 다시 다운로드해야 합니다.';

  @override
  String get cacheCleared => '캐시 지워짐';

  @override
  String get cantClearCache => '캐시를 지울 수 없습니다';

  @override
  String get openFolder => '폴더 열기';

  @override
  String get cacheLimit => '캐시 한도';

  @override
  String get cacheLimitHint => '다운로드한 곡의 최대 디스크 사용량';

  @override
  String get about => '정보';

  @override
  String get version => '버전';

  @override
  String get discordPresence => 'Discord 상태 표시';

  @override
  String get discordPresenceHint => 'Discord 프로필에 재생 중인 곡을 표시합니다';

  @override
  String get discordEnabled => '상태 표시 활성화';

  @override
  String get editMetadata => '메타데이터 편집';

  @override
  String get metadataTitle => '제목';

  @override
  String get metadataArtist => '아티스트';

  @override
  String get metadataAlbum => '앨범';

  @override
  String get metadataCoverUrl => '커버 URL';

  @override
  String get metadataSaved => '메타데이터가 업데이트되었습니다';

  @override
  String get metadataSearchDeezer => 'Deezer에서 검색';

  @override
  String get metadataNotFound => 'Deezer에서 메타데이터를 찾을 수 없습니다';

  @override
  String get metadataCoverError => '이미지를 복사할 수 없습니다';

  @override
  String get metadataSearchOnline => '온라인 검색';

  @override
  String get metadataOnlineHint => '제목과 아티스트(또는 Spotify URL 붙여넣기)';

  @override
  String get metadataNoResults => '결과 없음';

  @override
  String get metadataApply => '적용';

  @override
  String get metadataSearchHint => 'Deezer는 이 양식의 제목과 아티스트로 검색합니다';

  @override
  String get lyrics => '가사';

  @override
  String get lyricsTitle => '가사';

  @override
  String get syncLyrics => '동기화';

  @override
  String get refreshLyrics => '가사 검색';

  @override
  String get lyricsNoTrack => '재생 중인 곡 없음';

  @override
  String get lyricsNotFound => '가사를 찾을 수 없습니다';

  @override
  String get lyricsNotFoundHint => '메타데이터 편집에서 아티스트 또는 제목을 수정해 보세요';

  @override
  String get karaokeSweep => '노래방';

  @override
  String get karaokeSweepHint => '노래에 맞춰 가사를 단어별로 강조합니다';

  @override
  String get done => '완료';

  @override
  String get importSpotify => '플레이리스트 가져오기';

  @override
  String get spotifyUrlHint => 'Spotify 또는 YouTube 재생목록 링크';

  @override
  String get importAction => '가져오기';

  @override
  String get spotifyFetchError => '플레이리스트를 읽을 수 없습니다(링크와 공개 여부를 확인하세요)';

  @override
  String get spotifyNoMatch => '일치 없음';

  @override
  String spotifyTruncated(int limit) {
    return '큰 플레이리스트: Premium 없이는 처음 $limit곡만 가져옵니다.';
  }

  @override
  String get karaokeSweepOn => '노래방: 켜짐';

  @override
  String get karaokeSweepOff => '노래방: 꺼짐';

  @override
  String get skipSilence => '무음 건너뛰기';

  @override
  String get skipSilenceHint => '재생 중 음악이 없는 무음 구간을 자동으로 건너뜁니다';

  @override
  String get syncLyricsTitle => '가사 동기화';

  @override
  String get syncCurrent => '현재';

  @override
  String get lyricsSearchNoResults => '결과를 찾을 수 없습니다';

  @override
  String get lyricsSearchError => '가사 검색 중 오류';

  @override
  String get lyricsSearchHint => '가사 검색 (제목 아티스트)';

  @override
  String get editLyrics => '가사 편집';

  @override
  String get useLyrics => '가사 사용';

  @override
  String get editLyricsHint => '여기에 LRC 붙여넣기: 줄마다 [mm:ss.xx] 텍스트';

  @override
  String get searchLyrics => '가사 검색';

  @override
  String get shareLyrics => '가사 공유';

  @override
  String get saveAsImage => '이미지로 저장';

  @override
  String get copyText => '복사';

  @override
  String get imageCopied => '이미지가 클립보드에 복사되었습니다';

  @override
  String get imageSaved => '이미지가 저장되었습니다';

  @override
  String shareOnSite(String site) {
    return '$site에서 공유';
  }

  @override
  String lineOfTotal(int index, int total) {
    return '총 $total줄 중 $index';
  }

  @override
  String get audioOutput => '오디오 출력';

  @override
  String get keyboardShortcuts => '키보드 단축키';

  @override
  String get shortcutPlayPause => '재생 / 일시정지';

  @override
  String get shortcutNext => '다음 곡';

  @override
  String get shortcutPrevious => '이전 곡';

  @override
  String get shortcutSeekForward => '10초 앞으로';

  @override
  String get shortcutSeekBackward => '10초 뒤로';

  @override
  String get shortcutVolumeUp => '볼륨 +5%';

  @override
  String get shortcutVolumeDown => '볼륨 -5%';

  @override
  String get shortcutMute => '음소거 / 음소거 해제';

  @override
  String get shortcutToggleLyrics => '가사 표시 전환';

  @override
  String get shortcutToggleQueue => '대기열 표시 전환';

  @override
  String get shortcutToggleSettings => '설정 표시 전환';

  @override
  String get shortcutClosePanel => '활성 패널 닫기';

  @override
  String get shortcutFullscreen => '전체 화면';

  @override
  String get shortcutToggleShuffle => '셔플 전환';

  @override
  String get shortcutToggleRepeat => '반복 전환';

  @override
  String get shortcutToggleRadio => '라디오 모드 전환';

  @override
  String get shortcutToggleFavorite => '즐겨찾기 추가 / 제거';

  @override
  String get shortcutCategoryPlayback => '재생';

  @override
  String get shortcutCategoryVolume => '볼륨';

  @override
  String get shortcutCategoryNavigation => '탐색';

  @override
  String get shortcutCategoryModes => '모드';

  @override
  String get shortcutMouseBack => '이전 곡 (마우스)';

  @override
  String get shortcutMouseForward => '다음 곡 (마우스)';

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
