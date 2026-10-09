#!/usr/bin/env bash
# Scrup — instalador para Linux (usuario final).
#
# Descarga el paquete .flatpak de la ÚLTIMA release de GitHub y lo instala para
# el usuario actual (sin root, sin sudo). El paquete es autocontenido: GTK3
# viene del runtime GNOME y libmpv/sqlite3/los sidecars (yt-dlp, ffmpeg, deno)
# viajan dentro, así que NO hay dependencias de sistema que instalar a mano.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/Frantt21/Scrup/main/install-linux.sh | bash
#   bash install-linux.sh                     # si ya lo tienes descargado
#   bash install-linux.sh --file <bundle.flatpak>   # instala un bundle local
#   bash install-linux.sh --dry-run           # muestra versión/URL y no instala
#   bash install-linux.sh --help
#
# Requisitos: flatpak y curl (si falta flatpak, el script te dice cómo ponerlo).
#
# Qué hace, en orden:
#   1. Comprueba Linux + flatpak + curl.
#   2. Resuelve la última release (API de GitHub) y el asset .flatpak.
#   3. Se asegura de que existe el remoto "flathub" (de ahí sale el runtime
#      org.gnome.Platform que el paquete necesita).
#   4. Descarga el bundle a un temporal y lo instala con --user (reinstala si
#      ya estaba instalado). Tus datos NO se tocan.
#   5. Retira la entrada de menú obsoleta de ~/.local/share/applications que
#      ENSOMBRECE la del flatpak (mismo desktop-id, y esa carpeta tiene
#      prioridad en XDG_DATA_DIRS) y refresca las cachés del escritorio.
#   6. Verifica la entrada exportada e imprime cómo ejecutar/actualizar.
#
# Tus datos (biblioteca, historial, ajustes, caché de audio) viven en
# ~/.var/app/com.scrup.scrup y se conservan al reinstalar o actualizar.
set -euo pipefail

APP_ID="com.scrup.scrup"
REPO_SLUG="Frantt21/Scrup"
RAW_URL="https://raw.githubusercontent.com/$REPO_SLUG/main/install-linux.sh"
API_URL="https://api.github.com/repos/$REPO_SLUG/releases/latest"
FLATHUB_REPO="https://dl.flathub.org/repo/flathub.flatpakrepo"

BUNDLE_FILE=""
DRY_RUN=0
TMP_DIR=""

TAG=""
URL=""
ASSET_NAME=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

usage() {
  cat <<EOF
Scrup — instalador para Linux (flatpak)

Descarga el paquete .flatpak de la última release de
https://github.com/$REPO_SLUG y lo instala para tu usuario (sin root).

Uso:
  curl -fsSL $RAW_URL | bash
  bash install-linux.sh                  # si ya lo tienes descargado
  bash install-linux.sh --file <ruta>    # instala un bundle .flatpak local
  bash install-linux.sh --dry-run        # resuelve y muestra, sin instalar
  bash install-linux.sh --help

Opciones:
  --file <ruta>  Instala el bundle indicado sin consultar GitHub (útil sin
                 conexión o para probar un build local).
  --dry-run      Muestra la versión y la URL que usaría, sin descargar ni
                 instalar nada.
  -h, --help     Muestra esta ayuda.

Tus datos (biblioteca, historial, ajustes, caché de audio) viven en
~/.var/app/$APP_ID y se conservan al reinstalar o actualizar.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die "--file necesita una ruta (usa --help)."
      BUNDLE_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "opción desconocida: $1 (usa --help)."
      ;;
  esac
done

# ── 1. Requisitos ────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ] || die "este instalador es solo para Linux."

if ! command -v curl >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Falta curl. Instálalo y vuelve a ejecutar el script:
  Debian/Ubuntu:  sudo apt install curl
  Fedora:         sudo dnf install curl
  Arch/CachyOS:   sudo pacman -S curl
  openSUSE:       sudo zypper install curl
EOF
  exit 1
fi

if ! command -v flatpak >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Falta flatpak. Instálalo y vuelve a ejecutar el script:
  Debian/Ubuntu:  sudo apt install flatpak
  Fedora:         sudo dnf install flatpak
  Arch/CachyOS:   sudo pacman -S flatpak
  openSUSE:       sudo zypper install flatpak

Después reinicia la sesión (o el equipo) para que el escritorio lo detecte.
EOF
  exit 1
fi

# ── 2. Origen del bundle ─────────────────────────────────────────────────────
if [ -n "$BUNDLE_FILE" ]; then
  [ -f "$BUNDLE_FILE" ] || die "no existe el fichero: $BUNDLE_FILE"
  BROWSER_URL=""
  ORIGIN="bundle local: $(realpath "$BUNDLE_FILE")"
else
  JSON="$(curl -fsSL -m 30 \
    -H 'Accept: application/vnd.github+json' \
    -H "User-Agent: scrup-installer" \
    "$API_URL" 2>/dev/null)" || die "no se pudo consultar la última release de $REPO_SLUG (¿sin conexión o límite de la API?).
Si tienes el paquete descargado, usa: bash install-linux.sh --file <ruta.flatpak>"

  TAG="$(printf '%s\n' "$JSON" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$TAG" ] || die "no se pudo leer la versión de la última release."

  # Primer asset cuyo nombre termine en .flatpak.
  BROWSER_URL="$(printf '%s\n' "$JSON" \
    | grep -o '"browser_download_url" *: *"[^"]*\.flatpak"' \
    | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  [ -n "$BROWSER_URL" ] || die "la release $TAG no trae ningún asset .flatpak."
  ASSET_NAME="$(basename "$BROWSER_URL")"
  ORIGIN="release $TAG ($ASSET_NAME)"
fi

if [ "$DRY_RUN" = 1 ]; then
  info "Origen: $ORIGIN"
  if [ -n "$BROWSER_URL" ]; then
    printf '    URL: %s\n' "$BROWSER_URL"
  fi
  printf '    Instalaría con: flatpak install --user -y <bundle>\n'
  printf '    (sin --dry-run hace la descarga e instalación de verdad)\n'
  exit 0
fi

# ── 3. Descarga (a un temporal que se borra al salir) ───────────────────────
cleanup() {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

if [ -n "$BUNDLE_FILE" ]; then
  FILE="$(realpath "$BUNDLE_FILE")"
else
  TMP_DIR="$(mktemp -d)"
  FILE="$TMP_DIR/$ASSET_NAME"
  info "Descargando $ORIGIN..."
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
    --progress-bar -o "$FILE" "$BROWSER_URL" \
    || die "no se pudo descargar el paquete."
  [ -s "$FILE" ] || die "la descarga quedó vacía."

  # El tamaño anunciado por el asset detecta cortes de CDN/proxy en una descarga
  # de ~90 MB. Es best-effort: si no se puede saber, se continúa.
  # OJO: las cabeceras llegan con CRLF ("content-length: 123\r"), así que hay
  # que quitar el \r o la comparación con el tamaño local falla siempre.
  EXPECTED="$(curl -fsSIL -m 30 "$BROWSER_URL" 2>/dev/null \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }')" || EXPECTED=""
  ACTUAL="$(stat -c%s "$FILE")"
  case "${EXPECTED:-}" in
    '' | *[!0-9]*) : ;; # tamaño desconocido: no se puede comprobar
    *)
      if [ "$EXPECTED" -ne "$ACTUAL" ]; then
        die "descarga incompleta ($ACTUAL de $EXPECTED bytes). Vuelve a intentarlo."
      fi
      ;;
  esac
fi

# ── 4. Runtime: el bundle necesita org.gnome.Platform, que viene de flathub ──
if ! flatpak remotes --columns=name 2>/dev/null | grep -qx 'flathub'; then
  info "Añadiendo el remoto 'flathub' (de ahí sale el runtime GNOME)..."
  flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO" \
    || warn "no se pudo añadir flathub; si falta el runtime, instálalo a mano."
fi

# ── 5. Instalación (--user: sin root; los datos se conservan) ───────────────
if flatpak info --user "$APP_ID" >/dev/null 2>&1; then
  info "Scrup ya estaba instalado: actualizando la versión (tus datos no se tocan)."
  if ! flatpak install --user --reinstall -y "$FILE"; then
    warn "'--reinstall' falló; se reinstala desde cero."
    printf '    (tus datos en ~/.var/app/%s se conservan: no se usa --delete-data)\n' "$APP_ID"
    flatpak uninstall --user -y "$APP_ID" || true
    flatpak install --user -y "$FILE"
  fi
else
  info "Instalando Scrup (solo para tu usuario)..."
  flatpak install --user -y "$FILE"
fi

# ── 6. Entrada del menú: retirar la obsoleta que ensombrece la del flatpak ───
# La entrada del flatpak se exporta a ~/.local/share/flatpak/exports/share/
# applications/. Si además existe una escrita a mano en
# ~/.local/share/applications/ con el MISMO desktop-id, gana la de esa carpeta
# (XDG_DATA_DIRS); si apunta a un --branch inexistente, el menú no lanza nada.
BRANCH="$(flatpak list --user --columns=application,branch "$APP_ID" 2>/dev/null \
  | awk -v id="$APP_ID" '$1 == id { print $2 }' | head -1)"
BRANCH="${BRANCH:-master}"
STALE="$HOME/.local/share/applications/$APP_ID.desktop"
if [ -f "$STALE" ]; then
  if grep -q 'flatpak run' "$STALE" && ! grep -q -- "--branch=$BRANCH" "$STALE"; then
    info "Retirando la entrada de menú obsoleta: $STALE"
    printf '    (invocaba "flatpak run" con una rama que no existe; copia en %s.bak)\n' "$STALE"
    mv "$STALE" "$STALE.bak"
  else
    warn "existe $STALE y ENSOMBRECE la entrada del flatpak (mismo id, y"
    warn "~/.local/share/applications tiene prioridad en XDG_DATA_DIRS)."
    warn "Si el icono del menú no lanza la app, muévelo: mv \"$STALE\" \"$STALE.bak\""
  fi
fi

# Refresca las cachés de menú/iconos del escritorio (best-effort; kbuildsycoca
# es la de KDE/Plasma, sin ella el icono no aparece hasta reiniciar plasmashell).
EXPORT_DIR="$HOME/.local/share/flatpak/exports/share/applications"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$EXPORT_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
  kbuildsycoca5 >/dev/null 2>&1 || true
fi

# ── 7. Verificación y resumen ───────────────────────────────────────────────
echo
EXPORTED="$EXPORT_DIR/$APP_ID.desktop"
if [ -f "$EXPORTED" ]; then
  info "Entrada de menú: $EXPORTED"
  grep -m1 '^Exec=' "$EXPORTED" | sed 's/^/    /' || true
else
  warn "no se exportó la entrada de menú ($EXPORTED)."
  warn "Prueba a ejecutarla con: flatpak run $APP_ID"
fi

VER="$(flatpak info --user "$APP_ID" 2>/dev/null \
  | sed -n 's/^ *Version: *//p' | head -1)"

echo
echo "==> Scrup instalado (solo para tu usuario)."
if [ -n "$VER" ]; then
  echo "    Versión:      $VER"
fi
echo "    Ejecutar:     flatpak run $APP_ID"
echo "    Actualizar:   volver a ejecutar este script"
echo "    Desinstalar:  flatpak uninstall --user $APP_ID"
echo "    Datos:        ~/.var/app/$APP_ID (biblioteca, historial, caché de audio)"
