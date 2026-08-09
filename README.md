# Scrup 🎵

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
- **Búsqueda**: busca canciones en YouTube y las reproduce al instante.
- **Playlists**: crea, elimina y añade canciones; reproduce toda la playlist
  como cola con auto-advance al terminar cada pista.
- **Title bar personalizado** (solo Windows): área de arrastre y botones de
  minimizar/maximizar/cerrar. En Linux y macOS se usa la title bar nativa de
  la distro/OS (cada gestor de ventanas dibuja la suya), con una barra
  superior ligera para volver/configuración.
- **Caché local de audio**: evicción LRU por tamaño (2 GiB por defecto),
  descargas con progreso y deduplicación de descargas concurrentes.
- **Reproducción progresiva**: al reproducir por primera vez, arranca el
  audio con los primeros datos del `.part` (sin esperar la descarga
  completa) y la descarga sigue en segundo plano hasta cachearse.
- **Metadatos vía Deezer**: al reproducir, se enriquece la pista con título/
  artista/álbum/portada limpios de la API pública de Deezer (best-effort,
  sin clave).
- **Tema dinámico**: el color de acento de la app se adapta al artwork de la
  pista en reproducción (paleta extraída con `palette_generator`).

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

> 💡 **Title bar por plataforma**: Windows usa la title bar personalizada
> (oculta la nativa vía `window_manager`). Linux y macOS conservan la title
> bar nativa del sistema — ocultarla en Linux depende del gestor de ventanas
> (Mutter, KWin, XFWM…) y es poco fiable, así que ahí solo se dibuja una
> barra superior con back + configuración.

> ⚠️ **`media_kit` + hot restart**: cada `R` crea un `Player` nativo (libmpv)
> nuevo en el mismo proceso. En Windows esto puede crashear la app. Si al
> pulsar `R` la app se cae o se pierde la conexión, usa `q` y relanza
> `flutter run -d windows` — es la vía más estable para cambios de servicios.

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
