# Scrup

Reproductor de música desde YouTube con **caché local y reproducción
progresiva**: descarga cada pista con `yt-dlp` y la reproduce desde archivo
con `media_kit` (motor mpv). La primera reproducción **empieza a sonar en
cuanto el `.part` tiene datos** (mientras la descarga continúa en segundo
plano y queda cacheada en disco); las siguientes se sirven al instante desde
el caché local, evitando los cortes de los streams remotos de YouTube.

Los metadatos, el historial y las playlists se guardan en una base local
SQLite (`drift`).

Plataformas objetivo: **Windows, Linux y macOS** (una sola base de código Flutter).

## Funcionalidades

- **Inicio**: reproducciones recientes (desde SQLite) en el arranque.
- **Búsqueda**: busca canciones y las reproduce al instante. Combina en
  paralelo **YouTube Music** (canciones canónicas con metadatos limpios,
  vía la API interna InnerTube) y YouTube general (`yt-dlp`): primero
  canciones reales del artista, después vídeos sueltos; sin duplicados y
  con degradación graceful si YT Music falla.
- **Importación de playlists**: pega un enlace y Scrup crea la playlist
  local automáticamente, con diálogo de emparejamiento en vivo (✓ por pista):
  - **Spotify** (enlace, URI `spotify:` o ID): lee la playlist pública sin
    API keys desde el embed web y empareja cada pista contra YouTube
    puntuando título normalizado + duración + artista. Límite honesto: el
    embed público expone solo las primeras ~100 pistas (la app avisa).
  - **YouTube / YouTube Music** (`list=…` o ID pelado): lectura completa vía
    InnerTube browse con paginación (sin límite práctico) y coincidencia
    exacta al 100 %: los videoIds ya vienen dados, no hay búsqueda.
- **Playlists**: crea, elimina y añade canciones; reproduce toda la playlist
  como cola con auto-advance al terminar cada pista. Incluye portada
  personalizada (imagen local o artwork de sus canciones) y descripción
  editable.
- **Favoritos**: playlist especial que no se puede borrar, con acceso rápido
  al corazón desde el reproductor.
- **Panel de cola**: lista deslizable desde la derecha para ver, reordenar y
  saltar entre canciones; su estado (abierto/cerrado) se restaura entre
  sesiones.
- **Modo radio**: al agotarse la cola, busca más canciones del mismo
  artista/género y sigue sonando (activo por defecto). Usa la misma búsqueda
  combinada (YouTube Music primero), así que propone canciones reales del
  artista en vez de vídeos random.
- **Title bar personalizada**: en las tres plataformas (Windows y Linux sin
  marco, macOS con los traffic lights nativos conservados).
- **Caché local de audio**: evicción LRU por tamaño (2 GiB por defecto),
  descargas con progreso y deduplicación de descargas concurrentes.
- **Reproducción progresiva**: al reproducir por primera vez, arranca el
  audio con los primeros datos del `.part` (sin esperar la descarga
  completa) y la descarga sigue en segundo plano hasta cachearse.
- **Metadatos vía Deezer**: al reproducir, se enriquece la pista con título/
  artista/álbum/portada limpios de la API pública de Deezer (best-effort,
  sin clave). También permite editar los metadatos a mano y re-buscar en
  Deezer o elegir una portada local.
- **Letras sincronizadas (LRCLIB)**: auto-scroll, modo karaoke palabra por
  palabra, tap-to-seek, búsqueda manual y ajuste de sincronización.
- **Controles multimedia nativos del OS**: SMTC en Windows, Now Playing en
  macOS y MPRIS en Linux (vía `audio_service` y sus paquetes compañeros).
- **Discord Rich Presence**: publica la canción en reproducción (título,
  artista, álbum, portada y cronómetro) a través del IPC local de Discord,
  sin librerías nativas (solo Dart + FFI del OS).
- **Tema dinámico**: el color de acento de la app se adapta al artwork de la
  pista en reproducción (paleta extraída con `palette_generator`).
- **Internacionalización**: interfaz en español, inglés, portugués
  (Brasil y Portugal), ruso, japonés, coreano y chino; el idioma se
  persiste entre sesiones.
- **Persistencia de sesión**: se restauran al arrancar el volumen, la cola
  completa (orden, índice y playlist activa), el punto de reanudación, los
  modos de shuffle/repetición y varias preferencias de UI.

## Arquitectura

```
┌──────────────────────────────────────────────────────────┐
│  UI Flutter (title bar, navegación, player bar, lyrics)  │
├──────────────────────────────────────────────────────────┤
│  yt-dlp → busca y descarga audio (progreso)              │  (subproceso + parseo JSON)
│  YtMusicService → YouTube Music vía InnerTube (búsqueda, │  (HTTP público, sin API key)
│                     playlists con paginación)             │
│  SearchService → fusión YT Music + yt-dlp (canciones     │
│                   primero, dedupe por videoId)           │
│  SpotifyImportService → lee playlists de Spotify (embed) │
│                          y las empareja contra YouTube   │
│  AudioCacheService → caché local con límite LRU          │  (2 GiB, evicción por mtime)
│  media_kit (libmpv) → reproduce archivo local            │
│  PlayerService → cola, repeat, shuffle, radio            │
│  LyricsService → letras sincronizadas (LRCLIB)           │
│  DeezerService → enriquecimiento de metadatos            │
│  DiscordPresenceService → Rich Presence (IPC + FFI)      │
│  ScrupAudioHandler → SMTC / Now Playing / MPRIS         │
│  drift (SQLite) → historial, playlists, favoritos        │
│  Binarios sidecar → yt-dlp + ffmpeg + deno por OS        │
└──────────────────────────────────────────────────────────┘
```

### Notas técnicas clave

- **YouTube Music vía InnerTube**: la búsqueda de canciones y la lectura de
  playlists usan la API interna de YouTube Music (`WEB_REMIX`), la misma
  técnica de herramientas como spotdl: sin API key ni login. Al ser un
  endpoint no documentado, todo lo que depende de él tiene fallback al
  `ytsearch` clásico de yt-dlp, así que la app nunca queda peor si cambia.
- **Importación de Spotify sin API keys**: se lee el embed web público
  (`__NEXT_DATA__`), que no requiere cuenta pero trunca en ~100 pistas y no
  expone el total. Con una app propia de Spotify Developer + Premium sería
  posible leer playlists completas vía Web API oficial (pendiente, el
  importador está preparado para caer del embed a la API).
- **El caché de audio vive en el directorio de soporte de la app**
  (`%APPDATA%/<org>/scrup/audio_cache` en Windows). Límite por defecto: 2 GiB,
  configurable con la variable de entorno `SCRUP_CACHE_MAX_MB` (en MiB).
- **Los streams remotos pueden cortarse** (expiración/rate-limit de YouTube);
  por eso la reproducción es cache-first: archivo local estable.
- El cifrado de firma lo resuelve `yt-dlp`; `mpv` reproduce el archivo final.
- `yt-dlp` se actualiza a menudo (YouTube cambia cosas): el script de binarios
  siempre descarga la versión más reciente.
- **Descarga automática de binarios**: si al arrancar no se encuentran
  `yt-dlp`/`ffmpeg`, la app intenta descargarlos sola (con curl o PowerShell)
  y avisa del progreso con un toast.
- **Presencia de Discord sin librerías nativas**: el cliente habla el IPC
  local de Discord (named pipe en Windows vía FFI, sockets Unix en
  Linux/macOS), con el Application ID de Scrup embebido. Solo hay que activar
  el interruptor en Configuración.
- **Controles nativos del OS**: en Windows `audio_service` no lo soporta por
  sí solo, así que se usa `audio_service_win` (SMTC); en Linux se usa
  `audio_service_mpris` (MPRIS) y en macOS el soporte nativo de Now Playing.
  Nota: `audio_service_win` no implementa la línea de tiempo, por lo que la
  barra de progreso/seek del SMTC no aparece en Windows.

## Requisitos

- Flutter SDK (stable) con soporte desktop: Windows, Linux o macOS.
- En Windows: Visual Studio Build Tools con el workload **"Desktop development
  with C++"** (incluye el Windows SDK).

## Puesta en marcha

```bash
# 1. (Opcional) Descargar binarios sidecar para tu plataforma
#    (yt-dlp + ffmpeg + deno). Si se omite, la app los descarga sola
#    la primera vez que arranca.
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
las variables de entorno `SCRUP_YTDLP_PATH`, `SCRUP_FFMPEG_PATH` y
`SCRUP_DENO_PATH`.

**deno (opcional pero recomendado)**: `fetch_binaries.sh` descarga también el
runtime JS de yt-dlp. yt-dlp 2026+ deprecó la extracción de YouTube sin
runtime JS ("some formats may be missing"); con deno en el PATH del
subproceso la extracción queda completa y a prueba del cierre del camino sin
JS. Si la descarga de deno falla, la app sigue funcionando (extracción
degradada), y también se detecta un deno ya instalado en el sistema.

## Flujo de desarrollo (importante)

**Regla de oro: nunca ejecutar `flutter build` mientras haya un `flutter run`
activo.** El build mata el proceso `scrup.exe` en ejecución (necesario para
poder sobrescribir el binario), lo que corta la conexión del modo debug
("Lost connection to device"). Si quieres el ejecutable, cierra primero la
sesión de desarrollo con `q`.

Mientras se itera, el ciclo es solo código + recarga en la consola de
`flutter run`:

| Tecla | Acción | Cuándo usarla |
|---|---|---|---|
| `r` | Hot reload | Cambios de UI/lógica que **no** tocan `main.dart` ni singletons |
| `R` | Hot restart | Cambios en `main.dart` o en `PlayerService` (singleton) |
| `q` | Quit | Cerrar la app y la sesión de debug |

> **Title bar por plataforma**: Windows y Linux usan la title bar
> personalizada (ocultan la nativa vía `window_manager` y dibujan sus propios
> botones de minimizar/maximizar/cerrar). macOS conserva los traffic lights
> nativos (oculta solo la barra con `TitleBarStyle.hidden`) y la barra deja
> espacio para ellos sin dibujar botones propios.

> **`media_kit` + hot restart**: cada `R` crea un `Player` nativo (libmpv)
> nuevo en el mismo proceso. En Windows esto puede crashear la app. Si al
> pulsar `R` la app se cae o se pierde la conexión, usa `q` y relanza
> `flutter run -d windows` — es la vía más estable para cambios de servicios.

## Estructura

```
lib/
├── core/              # Binaries (resolución sidecar), Track, letras y utilidades
│   ├── binaries.dart              # Resolución y descarga automática de sidecars
│   ├── track.dart                 # Modelo de pista
│   ├── title_cleaner.dart         # Limpieza de títulos de YouTube
│   ├── queue_shuffle.dart         # Barajado de la cola
│   ├── synced_lyrics.dart         # Modelo de letras sincronizadas (LRC)
│   └── lyrics_search_result.dart  # DTO de resultados de LRCLIB
├── data/              # Drift: tablas, DB, historial, playlists y favoritos
├── l10n/              # ARB de idiomas (es, en, pt, pt_BR, ru, ja, ko, zh)
│   └── generated/     # AppLocalizations generado
├── services/
│   ├── ytdlp_service.dart             # Subprocesos yt-dlp (buscar/descargar)
│   ├── ytmusic_service.dart           # YouTube Music vía InnerTube: búsqueda
│   │                                  #  de canciones y playlists paginadas
│   ├── search_service.dart            # Fusión YT Music + yt-dlp con dedupe
│   ├── spotify_import_service.dart    # Lectura de playlists de Spotify (embed)
│   │                                  #  + emparejamiento contra YouTube
│   ├── audio_cache_service.dart       # Caché local con LRU y precarga
│   ├── player_service.dart            # Cola, repeat, shuffle, radio
│   ├── deezer_service.dart            # Metadatos y portadas vía Deezer
│   ├── lyrics_service.dart            # Letras sincronizadas (LRCLIB)
│   ├── scrup_audio_handler.dart       # SMTC / Now Playing / MPRIS
│   ├── palette_cache_store.dart       # Caché en disco de colores de artwork
│   ├── playlist_cover_store.dart      # Copia de portadas elegidas por el usuario
│   ├── settings_store.dart            # Preferencias persistidas de la sesión
│   └── discord/                       # Rich Presence (IPC + FFI, sin nativas)
└── ui/
    ├── app_shell.dart         # Title bar + navegación + player bar + panel de cola
    ├── playback.dart          # Helpers playTrack / playQueue
    ├── locale_controller.dart # Cambio de idioma en caliente
    ├── theme_controller.dart  # Acento dinámico desde el artwork
    ├── playlist_actions.dart  # Modal "añadir a playlist"
    ├── views/                 # Home, Search, PlaylistDetail, Lyrics, Settings
    └── widgets/               # CustomTitleBar, PlayerBar, TrackTile, QueuePanel,
                               # PlaylistsSidebar, LyricsDisplay, CoverImage,
                               # SpotifyImportDialog (importar de Spotify/YouTube)
tool/
└── fetch_binaries.sh   # Descarga yt-dlp + ffmpeg + deno por SO
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
