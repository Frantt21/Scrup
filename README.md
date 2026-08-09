# Scrup 🎵

Reproductor de música desde YouTube con **caché local**: descarga cada pista
con `yt-dlp` y la reproduce desde archivo con `media_kit` (motor mpv). Las
primeras reproducciones descargan la pista (con progreso en la barra del
reproductor); las siguientes se sirven al instante desde el caché local,
evitando los cortes de los streams remotos de YouTube.

Los metadatos, el historial y las playlists se guardan en una base local
SQLite (`drift`).

Plataformas objetivo: **Windows, Linux y macOS** (una sola base de código Flutter).

## Funcionalidades

- **Inicio**: reproducciones recientes (desde SQLite) en el arranque.
- **Búsqueda**: busca canciones en YouTube y las reproduce al instante.
- **Playlists**: crea, elimina y añade canciones; reproduce toda la playlist
  como cola con auto-advance al terminar cada pista.
- **Title bar personalizado** (Windows/Linux): área de arrastre y botones de
  minimizar/maximizar/cerrar.
- **Caché local de audio**: evicción LRU por tamaño (2 GiB por defecto),
  descargas con progreso y deduplicación de descargas concurrentes.

## Arquitectura

```
┌──────────────────────────────────────────────────┐
│  UI Flutter (title bar, navegación, player bar)  │
├──────────────────────────────────────────────────┤
│  yt-dlp → busca y descarga audio (progreso)      │  (subproceso + parseo JSON)
│  AudioCacheService → caché local con límite LRU  │  (2 GiB, evicción por mtime)
│  media_kit (libmpv) → reproduce archivo local    │
│  PlayerService → cola, repeat, shuffle, radio    │
│  drift (SQLite) → historial, playlists           │
│  Binarios sidecar → yt-dlp + ffmpeg por OS       │
└──────────────────────────────────────────────────┘
```

### Notas técnicas clave

- **El caché de audio vive en el directorio de soporte de la app**
  (`%APPDATA%/<org>/scrup/audio_cache` en Windows). Límite por defecto: 2 GiB,
  configurable con `SCRUP_CACHE_MAX_MB` si se expone.
- **Los streams remotos pueden cortarse** (expiración/rate-limit de YouTube);
  por eso la reproducción es cache-first: archivo local estable.
- El cifrado de firma lo resuelve `yt-dlp`; `mpv` reproduce el archivo final.
- `yt-dlp` se actualiza a menudo (YouTube cambia cosas): el script de binarios
  siempre descarga la versión más reciente.

## Requisitos

- Flutter SDK (stable) con soporte desktop: Windows, Linux o macOS.
- En Windows: Visual Studio Build Tools con el workload **"Desktop development
  with C++"** (incluye el Windows SDK).

## Puesta en marcha

```bash
# 1. Descargar binarios sidecar para tu plataforma (yt-dlp + ffmpeg)
bash tool/fetch_binaries.sh

# 2. Generar código de drift (tras cambiar las tablas)
dart run build_runner build

# 3. Ejecutar en desarrollo
flutter run -d windows   # o -d linux / -d macos

# 4. Compilar
flutter build windows    # o build linux / build macos
```

Los binarios sidecar se copian junto al ejecutable en el build (o se resuelven
desde `bin/<plataforma>/` en desarrollo). También puedes anular sus rutas con
las variables de entorno `SCRUP_YTDLP_PATH` y `SCRUP_FFMPEG_PATH`.

## Estructura

```
lib/
├── core/          # Binaries (resolución sidecar) y modelo Track
├── data/          # Drift: tablas, DB, historial y playlists
├── services/      # YtDlpService, AudioCacheService y PlayerService
└── ui/
    ├── app_shell.dart        # Title bar + navegación + player bar
    ├── playback.dart         # Helper playTrack / playQueue
    ├── views/                # HomeView, SearchView, PlaylistsView, PlaylistDetail
    └── widgets/              # CustomTitleBar, PlayerBar, TrackTile
tool/
└── fetch_binaries.sh   # Descarga yt-dlp + ffmpeg por SO
bin/<plataforma>/       # Binarios sidecar (no versionados)
```

## Comandos de validación

```bash
flutter analyze
flutter test
```

## Si mueves el proyecto de carpeta

El cache de CMake guarda las rutas absolutas. Tras mover el proyecto a otra
ubicación (o deshacer una carpeta duplicada), limpia los caches antes de
recompilar:

```bash
rm -rf build .dart_tool
flutter pub get
dart run build_runner build
flutter build windows
```

Después, recuerda volver a copiar los binarios sidecar junto al ejecutable
(`cp bin/windows/yt-dlp.exe build/windows/x64/runner/Debug/` y lo mismo con
`ffmpeg/`), o simplemente ejecuta `tool/fetch_binaries.sh` desde el build.
