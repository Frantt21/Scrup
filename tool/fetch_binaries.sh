#!/usr/bin/env bash
# Scrup - descarga los binarios sidecar (yt-dlp + ffmpeg) para la plataforma actual.
# Uso:  bash tool/fetch_binaries.sh
# Salida: bin/<windows|linux|macos>/{yt-dlp, ffmpeg/ffmpeg, ffprobe}
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"

# --- Detectar plataforma -----------------------------------------------------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows"; EXT=".exe" ;;
  Linux*)               PLATFORM="linux";   EXT="" ;;
  Darwin*)              PLATFORM="macos";   EXT="" ;;
  *) echo "Plataforma no soportada: $(uname -s)"; exit 1 ;;
esac

DEST="$BIN/$PLATFORM"
mkdir -p "$DEST/ffmpeg"

echo "==> Plataforma: $PLATFORM  (destino: $DEST)"

# --- yt-dlp ---------------------------------------------------------------
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp$EXT"
echo "==> Descargando yt-dlp..."
curl -L --fail --progress-bar -o "$DEST/yt-dlp$EXT" "$YTDLP_URL"
chmod +x "$DEST/yt-dlp$EXT" 2>/dev/null || true
"$DEST/yt-dlp$EXT" --version

# --- ffmpeg ---------------------------------------------------------------
case "$PLATFORM" in
  windows)
    # Build esencial (gyan.dev): ffmpeg-release-essentials.zip
    ZIP="$DEST/ffmpeg-tmp.zip"
    echo "==> Descargando ffmpeg (gyan.dev essentials)..."
    curl -L --fail --progress-bar -o "$ZIP" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    # Extraer solo los binarios
    rm -f "$DEST/ffmpeg/ffmpeg$EXT" "$DEST/ffmpeg/ffprobe$EXT"
    unzip -j -o "$ZIP" "*/bin/ffmpeg.exe" "*/bin/ffprobe.exe" -d "$DEST/ffmpeg" >/dev/null
    rm -f "$ZIP"
    ;;
  linux)
    # Build estático (johnvansickle): ffmpeg-release-amd64-static.tar.xz
    TAR="$DEST/ffmpeg-tmp.tar.xz"
    echo "==> Descargando ffmpeg (johnvansickle static)..."
    curl -L --fail --progress-bar -o "$TAR" "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
    rm -f "$DEST/ffmpeg/ffmpeg" "$DEST/ffmpeg/ffprobe"
    tar -xJf "$TAR" -C "$DEST/ffmpeg" --strip-components=1 --wildcards "*/ffmpeg" "*/ffprobe"
    rm -f "$TAR"
    if [ ! -x "$DEST/ffmpeg/ffmpeg" ] || [ ! -x "$DEST/ffmpeg/ffprobe" ]; then
      echo "ERROR: la extracción de ffmpeg no produjo los binarios esperados" >&2
      exit 1
    fi
    ;;
  macos)
    # Build de evermeet: ffmpeg-x.x.zip (x86_64) - para Apple Silicon usa homebrew
    ZIP="$DEST/ffmpeg-tmp.zip"
    echo "==> Descargando ffmpeg (evermeet)..."
    # Normaliza la versión a formato mayor.menor (evermeet no publica patches)
    FFMPEG_VERSION=$(curl -s "https://evermeet.cx/ffmpeg/info/ffmpeg/release" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 | awk -F. '{print $1"."$2}')
    FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
    echo "    ffmpeg versión: $FFMPEG_VERSION"
    curl -L --fail --progress-bar -o "$ZIP" "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/$FFMPEG_VERSION"
    rm -f "$DEST/ffmpeg/ffmpeg" "$DEST/ffmpeg/ffprobe"
    unzip -j -o "$ZIP" -d "$DEST/ffmpeg" >/dev/null
    # ffprobe viene en un zip separado en evermeet
    curl -L --fail --progress-bar -o "$ZIP" "https://evermeet.cx/ffmpeg/getrelease/ffprobe/$FFMPEG_VERSION"
    unzip -j -o "$ZIP" -d "$DEST/ffmpeg" >/dev/null
    rm -f "$ZIP"
    echo "    Nota: en Apple Silicon (arm64) considera instalar ffmpeg vía homebrew: brew install ffmpeg"
    ;;
esac

chmod +x "$DEST/ffmpeg/ffmpeg" "$DEST/ffmpeg/ffprobe" 2>/dev/null || true
echo "==> ffmpeg:"
"$DEST/ffmpeg/ffmpeg" -version | head -1
echo "==> Listo. Binarios en $DEST"
