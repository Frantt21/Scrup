/* Scrup - Android python3 interpreter driver.
 *
 * Builds against the official python.org "Android embeddable package"
 * (python-X.Y.Z-aarch64-linux-android.tar.gz), which ships libpython3.14.so,
 * the full stdlib and headers but NO interpreter executable. This tiny driver
 * uses only the stable public C API (Py_BytesMain) so it links cleanly
 * against the shared libpython and behaves exactly like stock `python3` for
 * CLI-style runs (script path, -c, -O, etc.).
 *
 * Compiled at fetch time by tool/fetch_android_toolchain.sh with the Android
 * NDK cross-clang and packaged as a native asset.
 */
#include <Python.h>

int main(int argc, char **argv)
{
    /* Parse argv exactly like CPython's native interpreter binary, then run
     * the given script (yt-dlp) or REPL. */
    return Py_BytesMain(argc, argv);
}