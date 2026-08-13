#!/usr/bin/env bash
# Instala la integración de escritorio de Scrup en Linux (Fedora/GNOME, etc.):
# el icono del dock y el nombre ("Scrup" en vez de "com.scrup.scrup").
#
# Uso:
#   flutter build linux --release
#   ./linux/install.sh                 # usa build/linux/x64/release/bundle
#   ./linux/install.sh <ruta-del-bundle>
#
# Genera:
#   ~/.local/share/icons/hicolor/<n>x<n>/apps/com.scrup.scrup.png
#   ~/.local/share/applications/com.scrup.scrup.desktop  (apunta al bundle)
#
# El .desktop tiene el MISMO id que el GApplication del runner (APPLICATION_ID),
# así GNOME asocia la ventana en ejecución con esta entrada y muestra el
# nombre y el icono correctos en el dock. Re-ejecuta el script tras cada
# rebuild para que la entrada siga apuntando al bundle más reciente.
set -euo pipefail

cd "$(dirname "$0")/.." # raíz del proyecto

BUNDLE="${1:-build/linux/x64/release/bundle}"
BIN="$BUNDLE/scrup"
if [ ! -x "$BIN" ]; then
  echo "No se encontró el bundle en: $BUNDLE" >&2
  echo "Compílalo primero con: flutter build linux --release" >&2
  exit 1
fi

APP_ID="com.scrup.scrup"
LOGO="assets/app-logo.png"
APPS_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"
BIN_ABS="$(realpath "$BIN")"

mkdir -p "$APPS_DIR"

# Icono en todos los tamaños estándar del tema hicolor (el dock usa 256/512).
for size in 16 32 48 128 256 512; do
  out="$ICON_BASE/${size}x${size}/apps/$APP_ID.png"
  mkdir -p "$(dirname "$out")"
  magick "$LOGO" -resize "${size}x${size}" "$out"
done

cat > "$APPS_DIR/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Scrup
GenericName=Music Player
Comment=Reproductor de música
# La ruta va ENTRE COMILLAS: el path del bundle puede contener espacios
# (p.ej. "Disco Local SSD") y sin ellas GIO rechaza toda la entrada.
Exec="$BIN_ABS"
Icon=$APP_ID
Terminal=false
Categories=AudioVideo;Audio;Music;Player;
Keywords=music;player;audio;
StartupWMClass=$APP_ID
EOF

# Refresca la base de datos de aplicaciones y la caché de iconos (best-effort).
command -v update-desktop-database >/dev/null && \
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null && \
  gtk-update-icon-cache -f -t "$ICON_BASE" >/dev/null 2>&1 || true

echo "OK: Scrup registrado en el escritorio."
echo "  Icono: $ICON_BASE/256x256/apps/$APP_ID.png"
echo "  Entrada: $APPS_DIR/$APP_ID.desktop"
echo "  Ejecutable: $BIN_ABS"
