# Scrup 🎵

Reproductor de música por **streaming** desde YouTube, sin descargar archivos.

Extrae la pista de audio con `yt-dlp`, reproduce su URL directa con `media_kit`
(motor mpv) y cachea los metadatos en una base local SQLite (`drift`).

Plataformas objetivo: **Windows, Linux y macOS** (una sola base de código Flutter).

## Arquitectura

```
┌────────────────────────────────────────────┐
│  UI Flutter (búsqueda, lista, player bar)  │
├────────────────────────────────────────────┤
│  yt-dlp  → busca pistas y extrae URL       │  (subproceso + parseo JSON)
│  media_kit (libmpv) → reproduce el stream  │  (sin escribir archivos)
│  drift (SQLite) → cache de metadatos       │  (título, artista, duración, historial)
│  Binarios sidecar → yt-dlp + ffmpeg por OS │  (embebidos junto al ejecutable)
└────────────────────────────────────────────┘
```

### Notas técnicas clave

- **Las URLs de audio de YouTube expiran (~6 h).** Nunca se cachean; se re-extraen
  con `yt-dlp` en el momento de reproducir (~1-2 s). Solo se cachean metadatos.
- El cifrado de firma lo resuelve `yt-dlp`; `mpv` reproduce la URL final.
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
├── data/          # Drift: tablas, DB y cache/historial
├── services/      # YtDlpService (extracción) y PlayerService (media_kit)
└── ui/            # HomePage + widgets (player bar, track tile)
tool/
└── fetch_binaries.sh   # Descarga yt-dlp + ffmpeg por SO
bin/<plataforma>/       # Binarios sidecar (no versionados)
```

## Comandos de validación

```bash
flutter analyze
flutter test
```
