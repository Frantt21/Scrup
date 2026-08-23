# Scrup

A music player for YouTube with **local caching and progressive
playback**: every track is downloaded via `yt-dlp` and played from file
with `media_kit` (mpv engine). The first play **starts sounding as soon as
the `.part` has data** (while the download continues in the background and
gets cached to disk); subsequent plays are served instantly from the local
cache, avoiding the dropouts of YouTube's remote streams.

Metadata, history and playlists are stored in a local SQLite database
(`drift`).

Target platforms: **Windows, Linux and macOS** (single Flutter codebase).

## Features

- **Home**: recent plays (from SQLite) on startup.
- **Search**: search songs and play them instantly. Combines **YouTube
  Music** (canonical songs with clean metadata, via the internal InnerTube
  API) and general YouTube (`yt-dlp`) in parallel: real artist songs first,
  then loose videos; no duplicates, with graceful degradation if YT Music
  fails.
- **Playlist import**: paste a link and Scrup creates the local playlist
  automatically, with a live matching dialog (per-track ✓):
  - **Spotify** (link, `spotify:` URI or ID): reads public playlists
    without API keys from the web embed and matches each track against
    YouTube scoring normalized title + duration + artist. Honest limit:
    the public embed only exposes the first ~100 tracks (the app warns
    you).
  - **YouTube / YouTube Music** (`list=…` or bare ID): complete read via
    InnerTube browse with pagination (no practical limit) and 100 % exact
    matching: videoIds come given, there is no searching.
- **Playlists**: create, delete and add songs; play the whole playlist as a
  queue with auto-advance after each track. Includes custom cover art
  (local image or artwork from its songs) and an editable description.
- **Favorites**: special playlist that cannot be deleted, with quick access
  from the heart button in the player.
- **Queue panel**: slide-in list from the right side to view, reorder and
  jump between songs; its state (open/closed) is restored across sessions.
- **Radio mode**: when the queue runs out, it searches more songs from the
  same artist/genre and keeps playing (on by default). Uses the same
  combined search (YouTube Music first), so it suggests the artist's real
  songs instead of random videos.
- **Custom title bar**: on all three platforms (Windows and Linux frameless,
  macOS keeping the native traffic lights).
- **Local audio cache**: LRU eviction by size (2 GiB by default), downloads
  with progress and deduplication of concurrent downloads.
- **Progressive playback**: when playing for the first time, audio starts
  with the first bytes of the `.part` file (no waiting for the full
  download) and the download keeps going in the background until cached.
- **Metadata via Deezer**: on playback, the track is enriched with clean
  title/artist/album/cover from Deezer's public API (best-effort, no key).
  You can also edit metadata manually and re-search Deezer or pick a local
  cover.
- **Synced lyrics (LRCLIB)**: auto-scroll, word-by-word karaoke mode,
  tap-to-seek, manual search and sync adjustment.
- **Native OS media controls**: SMTC on Windows, Now Playing on macOS and
  MPRIS on Linux (via `audio_service` and companion packages).
- **Discord Rich Presence**: publishes the playing song (title, artist,
  album, cover and timer) through Discord's local IPC, without native
  libraries (pure Dart + OS FFI).
- **Dynamic theme**: the app's accent color adapts to the playing track's
  artwork (palette extracted with `palette_generator`).
- **Internationalization**: interface in Spanish, English, Portuguese
  (Brazil and Portugal), Russian, Japanese, Korean and Chinese; the
  language persists across sessions.
- **Session persistence**: volume, the whole queue (order, index and active
  playlist), resume position, shuffle/repeat modes and several UI
  preferences are restored on startup.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Flutter UI (title bar, navigation, player bar, lyrics)  │
├──────────────────────────────────────────────────────────┤
│  yt-dlp → searches and downloads audio (progress)        │  (subprocess + JSON parsing)
│  YtMusicService → YouTube Music via InnerTube (search,   │  (public HTTP, no API key)
│                     paginated playlists)                  │
│  SearchService → merges YT Music + yt-dlp (songs first,  │
│                   dedupe by videoId)                      │
│  SpotifyImportService → reads Spotify playlists (embed)  │
│                          and matches them against YouTube │
│  AudioCacheService → local cache with LRU limit          │  (2 GiB, mtime eviction)
│  media_kit (libmpv) → plays local file                   │
│  PlayerService → queue, repeat, shuffle, radio           │
│  LyricsService → synced lyrics (LRCLIB)                  │
│  DeezerService → metadata enrichment                     │
│  DiscordPresenceService → Rich Presence (IPC + FFI)      │
│  ScrupAudioHandler → SMTC / Now Playing / MPRIS         │
│  drift (SQLite) → history, playlists, favorites          │
│  Sidecar binaries → yt-dlp + ffmpeg + deno per OS        │
└──────────────────────────────────────────────────────────┘
```

### Key technical notes

- **The audio cache lives in the app support directory**
  (`%APPDATA%/<org>/scrup/audio_cache` on Windows). Default limit: 2 GiB,
  configurable with the environment variable `SCRUP_CACHE_MAX_MB` (in MiB).
- **Remote streams can cut out** (YouTube expiry/rate-limit); that is why
  playback is cache-first: stable local file.
- Signature ciphering is handled by `yt-dlp`; `mpv` plays the final file.
- `yt-dlp` updates often (YouTube changes things): the binaries script
  always fetches the latest version.
- **Automatic binary download**: if `yt-dlp`/`ffmpeg` are not found at
  startup, the app tries to download them itself (with curl or PowerShell)
  and reports progress with a toast.
- **YouTube Music via InnerTube**: song search and playlist reading use
  YouTube Music's internal API (`WEB_REMIX`) — the same technique as tools
  like spotdl: no API key, no login. Since it's an undocumented endpoint,
  everything relying on it falls back to yt-dlp's classic `ytsearch`, so
  the app never gets worse if it changes.
- **Spotify import without API keys**: playlists are read from the public
  web embed (`__NEXT_DATA__`), which requires no account but truncates at
  ~100 tracks and exposes no total count. With your own Spotify Developer
  app + Premium, full playlists would be possible via the official Web API
  (pending; the importer is ready to fall back from embed to API).
- **Discord presence without native libraries**: the client speaks
  Discord's local IPC (named pipe on Windows via FFI, Unix sockets on
  Linux/macOS), with Scrup's Application ID embedded. Just flip the switch
  in Settings.
- **Native OS controls**: on Windows `audio_service` doesn't support them
  alone, so `audio_service_win` (SMTC) is used; on Linux
  `audio_service_mpris` (MPRIS), and native Now Playing support on macOS.
  Note: `audio_service_win` doesn't implement the timeline, so the SMTC
  progress bar/seek doesn't appear on Windows.

## Requirements

- Flutter SDK (stable) with desktop support: Windows, Linux or macOS.
- On Windows: Visual Studio Build Tools with the **"Desktop development
  with C++"** workload (includes the Windows SDK).

## Getting started

```bash
# 1. (Optional) Download sidecar binaries for your platform
#    (yt-dlp + ffmpeg + deno). If skipped, the app downloads them itself
#    the first time it starts.
bash tool/fetch_binaries.sh

# 2. Generate drift code (after changing tables)
dart run build_runner build

# 3. Run in development
flutter run -d windows   # or -d linux / -d macos

# 4. Build
flutter build windows    # or build linux / build macos
```

Sidecar binaries are copied next to the executable in the build (or
resolved from `bin/<platform>/` in development). You can also override
their paths with the environment variables `SCRUP_YTDLP_PATH`,
`SCRUP_FFMPEG_PATH` and `SCRUP_DENO_PATH`.

**deno (optional but recommended)**: `fetch_binaries.sh` also downloads
yt-dlp's JS runtime. yt-dlp 2026+ deprecated YouTube extraction without a
JS runtime ("some formats may be missing"); with deno in the subprocess
PATH extraction stays complete and safe from the no-JS shutdown. If the
deno download fails, the app still works (degraded extraction), and an
already-installed system deno is detected too.

## Development workflow (important)

**Golden rule: never run `flutter build` while a `flutter run` session is
active.** The build kills the running `scrup.exe` process (needed to
overwrite the binary), which cuts the debug connection ("Lost connection to
device"). If you want the executable, close the dev session with `q`
first.

While iterating, the cycle is just code + reload in the `flutter run`
console:

| Key | Action | When to use |
|---|---|---|
| `r` | Hot reload | UI/logic changes that **don't** touch `main.dart` or singletons |
| `R` | Hot restart | Changes in `main.dart` or `PlayerService` (singleton) |
| `q` | Quit | Close the app and the debug session |

> **Title bar per platform**: Windows and Linux use the custom title bar
> (native one hidden via `window_manager`, drawing their own
> minimize/maximize/close buttons). macOS keeps the native traffic lights
> (only the bar is hidden with `TitleBarStyle.hidden`) and the bar leaves
> room for them without drawing its own buttons.

> **`media_kit` + hot restart**: every `R` creates a new native `Player`
> (libmpv) in the same process. On Windows this can crash the app. If
> pressing `R` crashes the app or loses the connection, use `q` and relaunch
> `flutter run -d windows` — it's the most stable route for service changes.

## Structure

```
lib/
├── core/              # Binaries (sidecar resolution), Track, lyrics and utilities
│   ├── binaries.dart              # Sidecar resolution and auto-download
│   ├── track.dart                 # Track model
│   ├── title_cleaner.dart         # YouTube title cleanup
│   ├── queue_shuffle.dart         # Queue shuffling
│   ├── synced_lyrics.dart         # Synced lyrics model (LRC)
│   └── lyrics_search_result.dart  # LRCLIB result DTO
├── data/              # Drift: tables, DB, history, playlists and favorites
├── l10n/              # Language ARBs (es, en, pt, pt_BR, ru, ja, ko, zh)
│   └── generated/     # Generated AppLocalizations
├── services/
│   ├── ytdlp_service.dart             # yt-dlp subprocesses (search/download)
│   ├── ytmusic_service.dart           # YouTube Music via InnerTube: song
│   │                                  #  search and paginated playlists
│   ├── search_service.dart            # YT Music + yt-dlp merge with dedupe
│   ├── spotify_import_service.dart    # Spotify playlist reading (embed)
│   │                                  #  + matching against YouTube
│   ├── audio_cache_service.dart       # Local cache with LRU and preload
│   ├── player_service.dart            # Queue, repeat, shuffle, radio
│   ├── deezer_service.dart            # Metadata and covers via Deezer
│   ├── lyrics_service.dart            # Synced lyrics (LRCLIB)
│   ├── scrup_audio_handler.dart       # SMTC / Now Playing / MPRIS
│   ├── palette_cache_store.dart       # Artwork color cache on disk
│   ├── playlist_cover_store.dart      # User-chosen cover copying
│   ├── settings_store.dart            # Persisted session preferences
│   └── discord/                       # Rich Presence (IPC + FFI, no natives)
└── ui/
    ├── app_shell.dart         # Title bar + navigation + player bar + queue panel
    ├── playback.dart          # playTrack / playQueue helpers
    ├── locale_controller.dart # Hot language switching
    ├── theme_controller.dart  # Dynamic accent from artwork
    ├── playlist_actions.dart  # "Add to playlist" modal
    ├── views/                 # Home, Search, PlaylistDetail, Lyrics, Settings
    └── widgets/               # CustomTitleBar, PlayerBar, TrackTile, QueuePanel,
                               # PlaylistsSidebar, LyricsDisplay, CoverImage,
                               # SpotifyImportDialog (import from Spotify/YouTube)
tool/
└── fetch_binaries.sh   # Downloads yt-dlp + ffmpeg + deno per OS
bin/<platform>/       # Sidecar binaries (not versioned)
```

## Validation commands

```bash
flutter analyze
flutter test
```

## If you move the project folder

CMake caches absolute paths. After moving the project elsewhere (or undoing
a duplicated folder), clear the caches before rebuilding:

```bash
rm -rf build .dart_tool
flutter pub get
dart run build_runner build
flutter build windows
```

Then remember to copy the sidecar binaries next to the executable again
(`cp bin/windows/yt-dlp.exe build/windows/x64/runner/Debug/` and likewise
for `ffmpeg/`), or simply run `tool/fetch_binaries.sh` from the build.
