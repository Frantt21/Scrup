# Scrup

A music player for YouTube with **local caching and progressive
playback**: every track is downloaded via `yt-dlp` and played from file
with `media_kit` (mpv engine). The first play **starts sounding as soon
as the `.part` has data** (while the download continues in the background
and gets cached to disk); subsequent plays are served instantly from the
local cache, avoiding the dropouts of YouTube's remote streams.

Metadata, history and playlists are stored in a local SQLite database
(`drift`).

Target platforms: **Windows, Linux and macOS** (single Flutter codebase).

## Features

### Playback
- **Progressive playback**: when playing for the first time, audio starts
  with the first bytes of the `.part` file (no waiting for the full
  download) and the download keeps going in the background until cached.
- **Queue**: play whole playlists or individual songs with auto-advance;
  reorder tracks by drag & drop (same pattern as playlists); state
  (order, index, active playlist) persists across sessions.
- **Shuffle / Repeat / Radio mode**: shuffle (Spotify-style: preserves
  original order), repeat off/all/one, and radio mode (auto-recommends
  same artist/genre when the queue runs out, on by default).
- **Audio output device selector**: dropdown next to the volume icon to
  switch between speakers, headphones, HDMI, etc. Works on Windows
  (WASAPI), Linux (PulseAudio/PipeWire/ALSA) and macOS (CoreAudio).
- **Silence skip**: automatically skips silent gaps in songs.
- **Local audio cache**: LRU eviction by size (configurable from 512 MB
  to unlimited in Settings), downloads with progress and deduplication.
  Subsequent plays are served instantly from disk.

### Search & import
- **Search**: search songs and play them instantly. Combines **YouTube
  Music** (canonical songs with clean metadata, via the internal InnerTube
  API) and general YouTube (`yt-dlp`) in parallel: real artist songs first,
  then loose videos; no duplicates, with graceful degradation if YT Music
  fails.
- **Playlist import**: paste a link and Scrup creates the local playlist
  automatically, with a live matching dialog (per-track ✓):
  - **Spotify** (link, `spotify:` URI or ID): reads public playlists
    without API keys from the web embed and matches each track against
    YouTube scoring normalized title + duration + artist.
  - **YouTube / YouTube Music** (`list=…` or bare ID): complete read via
    InnerTube browse with pagination and 100% exact matching.
- **Search within playlists**: filter tracks inside any playlist.

### Lyrics
- **Synced lyrics**: auto-scroll with word-by-word karaoke mode, loaded
  from multiple providers (LRCLIB, KPoe) with automatic fallback.
- **Provider selector**: choose which API to search for lyrics (or auto).
- **Tap-to-seek**: tap any line to jump to that position.
- **Manual search and sync**: search lyrics manually, adjust timing
  offset, or paste raw LRC.

### UI & experience
- **Dynamic theme**: accent color adapts to the playing track's artwork
  (palette extracted with `palette_generator`); manual recalculation from
  the track's context menu or Settings.
- **Fullscreen mode**: immersive view with animated liquid background,
  large artwork and lyrics.
- **Custom title bar**: on all three platforms (Windows and Linux
  frameless, macOS keeping the native traffic lights).
- **Queue panel**: slide-in list from the right side with drag & drop
  reorder; its state (open/closed) is restored across sessions.
- **Pointer cursor**: all buttons, dropdowns, context menus and
  interactive elements show the hand cursor on hover.
- **Context menus**: right-click on any track (home, playlist, player)
  for quick actions: play, add to playlist, edit metadata, recalculate
  colors.
- **Metadata via Deezer**: on playback, the track is enriched with clean
  title/artist/album/cover from Deezer's public API (best-effort, no key).
  You can also edit metadata manually and re-search Deezer or pick a local
  cover.
- **Favorites**: special playlist that cannot be deleted, with quick access
  from the heart button in the player.

### Discord
- **Rich Presence**: publishes the playing song (title, artist, album,
  cover and timer) through Discord's local IPC, without native libraries
  (pure Dart + OS FFI).
- **Dynamic title**: the Discord header shows the song title instead of
  the app name.
- **Pause support**: the progress bar and timer freeze when paused and
  resume when playing.
- **Small icon**: optional app icon in the presence thumbnail (configurable
  in the Discord Developer Portal).

### Settings
- **Keyboard shortcuts**: full list displayed in a categorized section
  (see Keyboard shortcuts below).
- **Cache limit**: choose from presets (512 MB – unlimited) or open the
  cache folder directly.
- **Lyrics mode**: toggle word-by-word karaoke sweep and silence skip.
- **Discord toggle**: enable/disable Rich Presence.
- **Language**: switch between 8 languages; persists across sessions.
- **Playlist recalculation**: recalculate artwork palettes for all songs
  in a playlist.

### Keyboard shortcuts

All shortcuts are disabled when a text field is focused (search, edit
metadata, etc.) to avoid conflicts.

#### Playback
| Key | Action |
|---|---|
| `Space` | Play / Pause |
| `N` | Next track |
| `P` | Previous track |
| `→` | Seek forward 10s |
| `←` | Seek backward 10s |
| `🖱️ ⏴` | Previous track (mouse side button) |
| `🖱️ ⏵` | Next track (mouse side button) |
| `F` | Add / remove from favorites |

#### Volume
| Key | Action |
|---|---|
| `↑` | Volume up 5% |
| `↓` | Volume down 5% |
| `M` | Mute / Unmute |

#### Navigation
| Key | Action |
|---|---|
| `L` | Toggle lyrics |
| `Q` | Toggle queue |
| `,` | Toggle settings |
| `Esc` | Close active panel |
| `F11` | Fullscreen |

#### Modes
| Key | Action |
|---|---|
| `S` | Toggle shuffle |
| `R` | Toggle repeat |
| `D` | Toggle radio |

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
│  AudioCacheService → local cache with LRU limit          │  (configurable, mtime eviction)
│  media_kit (libmpv) → plays local file + audio devices   │
│  PlayerService → queue, repeat, shuffle, radio, devices  │
│  LyricsService → synced lyrics (LRCLIB, KPoe)            │
│  DeezerService → metadata enrichment                     │
│  DiscordPresenceService → Rich Presence (IPC + FFI)      │
│  ScrupAudioHandler → SMTC / Now Playing / MPRIS         │
│  drift (SQLite) → history, playlists, favorites          │
│  Sidecar binaries → yt-dlp + ffmpeg + deno per OS        │
└──────────────────────────────────────────────────────────┘
```

### Key technical notes

- **The audio cache lives in the app support directory**
  (`%APPDATA%/<org>/scrup/audio_cache` on Windows). Default limit:
  configurable in Settings (512 MB to unlimited), or via the environment
  variable `SCRUP_CACHE_MAX_MB` (in MiB).
- **Remote streams can cut out** (YouTube expiry/rate-limit); that is why
  playback is cache-first: stable local file.
- Signature ciphering is handled by `yt-dlp`; `mpv` plays the final file.
- `yt-dlp` updates often (YouTube changes things): the binaries script
  always fetches the latest version.
- **Automatic binary download**: if `yt-dlp`/`ffmpeg` are not found at
  startup, the app tries to download them itself (with curl or PowerShell)
  and reports progress with a toast. Binaries are stored in a `tools/`
  subfolder next to the executable.
- **YouTube Music via InnerTube**: song search and playlist reading use
  YouTube Music's internal API (`WEB_REMIX`) — the same technique as tools
  like spotdl: no API key, no login. Since it's an undocumented endpoint,
  everything relying on it falls back to yt-dlp's classic `ytsearch`, so
  the app never gets worse if it changes.
- **Spotify import without API keys**: playlists are read from the public
  web embed (`__NEXT_DATA__`), which requires no account but truncates at
  ~100 tracks and exposes no total count.
- **Discord presence without native libraries**: the client speaks
  Discord's local IPC (named pipe on Windows via FFI, Unix sockets on
  Linux/macOS), with Scrup's Application ID embedded. The `name` field
  in the payload shows the song title as the Discord header. Just flip
  the switch in Settings.
- **Audio device selection**: `media_kit` (libmpv) enumerates output
  devices natively per platform (WASAPI/PulseAudio/ALSA/CoreAudio) and
  allows switching at runtime via the dropdown next to the volume icon.
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

# 3. Generate version from pubspec.yaml
dart run tool/gen_version.dart

# 4. Run in development
flutter run -d windows   # or -d linux / -d macos

# 5. Build
flutter build windows    # or build linux / build macos
```

Sidecar binaries are stored in a `tools/` subfolder next to the
executable in the build (or resolved from `bin/<platform>/` in
development). You can also override their paths with the environment
variables `SCRUP_YTDLP_PATH`, `SCRUP_FFMPEG_PATH` and `SCRUP_DENO_PATH`.

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
│   ├── lyrics_search_result.dart  # LRCLIB result DTO
│   └── version.g.dart            # Generated version from pubspec.yaml
├── data/              # Drift: tables, DB, history, playlists and favorites
├── l10n/              # Language ARBs (es, en, pt, pt_BR, ru, ja, ko, zh)
│   └── generated/     # Generated AppLocalizations
├── services/
│   ├── ytdlp_service.dart             # yt-dlp subprocesses (search/download)
│   ├── ytmusic_service.dart           # YouTube Music via InnerTube
│   ├── search_service.dart            # YT Music + yt-dlp merge with dedupe
│   ├── spotify_import_service.dart    # Spotify playlist reading (embed)
│   ├── audio_cache_service.dart       # Local cache with LRU and preload
│   ├── player_service.dart            # Queue, repeat, shuffle, radio, audio devices
│   ├── deezer_service.dart            # Metadata and covers via Deezer
│   ├── lyrics_service.dart            # Synced lyrics (LRCLIB, KPoe)
│   ├── scrup_audio_handler.dart       # SMTC / Now Playing / MPRIS
│   ├── artwork_palette_service.dart   # Artwork color extraction
│   ├── palette_cache_store.dart       # Artwork color cache on disk
│   ├── artwork_cache_service.dart     # Artwork image cache
│   ├── playlist_cover_store.dart      # User-chosen cover copying
│   ├── settings_store.dart            # Persisted session preferences
│   ├── silence_skip_service.dart      # Auto-skip silent gaps
│   └── discord/                       # Rich Presence (IPC + FFI)
├── ui/
│   ├── app_shell.dart         # Title bar + navigation + keyboard shortcuts + mouse buttons
│   ├── playback.dart          # playTrack / playQueue helpers
│   ├── locale_controller.dart # Hot language switching
│   ├── theme_controller.dart  # Dynamic accent from artwork
│   ├── playlist_actions.dart  # "Add to playlist" modal
│   ├── views/                 # Home, Search, PlaylistDetail, Lyrics, Settings
│   └── widgets/               # CustomTitleBar, PlayerBar, TrackTile, QueuePanel,
│                               # PlaylistsSidebar, LyricsDisplay, CoverImage,
│                               # ContextMenuItem, SpotifyImportDialog
└── tool/
    ├── fetch_binaries.sh      # Downloads yt-dlp + ffmpeg + deno per OS
    ├── gen_version.dart       # Generates version.g.dart from pubspec.yaml
    └── gen_logo.dart          # Logo generation utility
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
dart run tool/gen_version.dart
flutter build windows
```

Then remember to copy the sidecar binaries next to the executable again
(or simply run `tool/fetch_binaries.sh` from the build).
