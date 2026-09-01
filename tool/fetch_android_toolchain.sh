#!/usr/bin/env bash
# Fetches the Android Python toolchain (CPython + yt-dlp) and packs it into
# android/app/src/main/assets/toolchain/<abi>/ as NATIVE Android assets
# (readable at runtime via the com.scrup.music.toolchain MethodChannel).
#
# Astral/python-build-standalone does NOT publish Android distributions, so we
# use the official python.org "Android embeddable package":
#     https://www.python.org/ftp/python/<PY_VERSION>/python-<PY_VERSION>-<abi>-linux-android.tar.gz
# which ships libpython + stdlib + headers but no executable. This script
# compiles the tiny interpreter driver (tool/android_python_driver.c) against
# it with the Android NDK cross-clang, giving a real python3 to exec.
#
# Requirements: bash, curl, tar, and the Android NDK (auto-detected via
# ANDROID_NDK_ROOT / ANDROID_NDK_HOME / ANDROID_HOME/ndk).
#
# Usage:
#   bash tool/fetch_android_toolchain.sh            # aarch64 (arm64-v8a), Python 3.14.7
#   ABIS="aarch64 x86_64" bash tool/fetch_android_toolchain.sh
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.14.7}"
ABIS="${ABIS:-aarch64}"                     # space-separated
YTDLP_VERSION="${YTDLP_VERSION:-latest}"    # tag or "latest"
OUT_BASE="${OUT_BASE:-android/app/src/main/assets/toolchain}"
DRIVER_SRC="${DRIVER_SRC:-tool/android_python_driver.c}"

WORK="${TMPDIR:-/tmp}/scrup_android_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log() { echo ">> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 2; }

# --- Android build tools ----------------------------------------------------
find_prebuilt() {
  local ndk="$1" prebuilt=""
  for p in windows-x86_64 linux-x86_64 darwin-x86_64 darwin-arm64; do
    if [[ -d "$ndk/toolchains/llvm/prebuilt/$p" ]]; then prebuilt="$ndk/toolchains/llvm/prebuilt/$p"; break; fi
  done
  [[ -n "$prebuilt" ]] || die "prebuilt LLVM toolchain no encontrado en $ndk"
  echo "$prebuilt"
}

find_ndk() {
  local ndk=""
  [[ -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]] && ndk="$ANDROID_NDK_ROOT"
  if [[ -z "$ndk" && -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then ndk="$ANDROID_NDK_HOME"; fi
  if [[ -z "$ndk" ]]; then
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -n "$sdk" && -d "$sdk/ndk" ]]; then
      ndk="$(ls -1 "$sdk/ndk" | sort -V | tail -n1)"
      ndk="$sdk/ndk/$ndk"
    fi
  fi
  [[ -n "$ndk" && -d "$ndk" ]] || die "NDK no encontrado (define ANDROID_NDK_ROOT o ANDROID_HOME/ndk)"
  echo "$ndk"
}

dl() { # url dest
  log "descargando $2 ($1)"
  # -sS: sin barra de progreso; -L --retry: fiable para redirects de GitHub.
  curl -sSL --retry 3 --connect-timeout 20 -o "$2" "$1"
}

# Build the python3 driver for an ABI and emit its path.
build_driver() {
  local abi="$1" prefix="$2" ndk prebuilt clang triple sysroot out
  case "$abi" in
    aarch64) triple="aarch64-linux-android24" ;;
    x86_64)  triple="x86_64-linux-android24"  ;;
    *) die "ABI no soportada: $abi (usa aarch64 o x86_64)" ;;
  esac
  ndk="$(find_ndk)"
  prebuilt="$(find_prebuilt "$ndk")"
  clang="$prebuilt/bin/clang"
  [[ -f "$prebuilt/bin/clang.exe" ]] && clang="$prebuilt/bin/clang.exe"
  sysroot="$prebuilt/sysroot"
  out="$WORK/$abi/driver/python3"
  mkdir -p "$(dirname "$out")"

  log "compilando driver python3 ($triple) con NDK"
  rpath_origin='-Wl,-rpath=$ORIGIN'
  rpath_lib='-Wl,-rpath=$ORIGIN/lib'
  "$clang" --target="$triple" --sysroot="$sysroot" -O2 \
    "-I$prefix/include/python3.14" \
    "$DRIVER_SRC" -o "$out" \
    "-L$prefix/lib" -lpython3.14 "$rpath_origin" "$rpath_lib" \
    -lm -ldl -llog

  echo "$out"
}

manifest_json() { # dir -> writes dir/manifest.json (pure bash, no jq/python)
  local dir="$1" rel first=1
  local tmp="${TMPDIR:-/tmp}/scrup_manifest_$$"
  ( cd "$dir" && find . -type f | sort | sed 's|^\./||' ) > "$tmp"
  { echo "{"
    echo '  "files": ['
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if [[ $first -eq 1 ]]; then first=0; else echo ","; fi
      printf '    "%s"' "$rel"
    done < "$tmp"
    echo ""
    echo '  ]'
    echo "}"; } > "$dir/manifest.json"
  rm -f "$tmp"
}

for abi in $ABIS; do
  log "== ABI: $abi =="
  a="$WORK/$abi"
  mkdir -p "$a"

  # 1. Official python.org android embeddable package.
  #    Nota: contiene un symlink (libsqlite3.so.0) que el tar de Windows no
  #    puede crear sin privilegios; el runtime no lo necesita (los DT_NEEDED
  #    apuntan a libsqlite3_python.so) así que se tolera el fallo.
  pyurl="https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-$abi-linux-android.tar.gz"
  dl "$pyurl" "$a/python.tar.gz"
  tar -xzf "$a/python.tar.gz" -C "$a" || true   # -> $a/prefix

  # 2. python3 interpreter driver (linked against $a/prefix/lib/libpython3.14.so).
  driver="$(build_driver "$abi" "$a/prefix")"

  # 3. yt-dlp zipapp (run with: python3 /path/yt-dlp ...).
  if [[ "$YTDLP_VERSION" == "latest" ]]; then
    yturl="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  else
    yturl="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp"
  fi
  dl "$yturl" "$a/yt-dlp"

  # 4. Assemble native assets (runtime layout: <files>/toolchain/<abi>/).
  out="$OUT_BASE/$abi"
  rm -rf "$out"
  mkdir -p "$out/lib"
  cp "$driver" "$out/python3"
  # -L: dereferencia symlinks para que cada librería quede como archivo real
  # (los assets nativos se leen byte a byte en runtime; sin links).
  cp -rL "$a/prefix/lib/." "$out/lib/"
  cp "$a/yt-dlp" "$out/yt-dlp"
  chmod +x "$out/python3" "$out/yt-dlp"

  # Trim dev/test-only stdlib pieces (keeps the APK lean).
  for d in test idlelib turtledemo tkinter site-packages __pycache__; do
    rm -rf "$out/lib/python3.14/$d"
  done
  rm -rf "$out/lib/python3.14"/config-3.14* "$out/lib/pkgconfig" "$out/lib/include"

  # aapt2 drops directories starting with '_' from APK assets.
  # Log which _-prefixed dirs exist so we know what to fix at runtime.
  _prefixed=$(find "$out/lib/python3.14" -type d -name '_*' ! -name '__*' 2>/dev/null || true)
  if [[ -n "$_prefixed" ]]; then
    echo "$_prefixed" | while read -r d; do
      log "aapt2 will strip: $(echo "$d" | sed "s|$out/lib/python3.14/||")"
    done
  fi

  # 5. File inventory for the runtime extractor (Dart reads the native assets).
  manifest_json "$out"

  log "empaquetado: $out ($(find "$out" -type f | wc -l) archivos, $(du -sh "$out" | cut -f1))"
done

log "listo. Ahora: flutter build apk --release (el APK incluye la toolchain como assets nativos)."