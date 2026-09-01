"""
Stub for zipfile._path — aapt2 strips _-prefixed directories from APK assets.

This module is injected into sys.modules by the Kotlin JNI driver before
yt-dlp is invoked, so that `from zipfile._path import ...` resolves correctly.
It only needs to provide the Path wrapper used by zipfile/__init__.py.
"""
import sys
import os
import io
import stat
import time


class Path:
    """Minimal Path shim for zipfile compatibility on Android."""
    __slots__ = ('_path',)

    def __init__(self, root, *parts):
        self._path = os.path.join(root, *parts) if parts else root

    def __truediv__(self, other):
        return Path(self._path, other)

    def __str__(self):
        return self._path

    def __repr__(self):
        return f'Path({self._path!r})'

    def open(self, mode='r', *a, **kw):
        return open(self._path, mode, *a, **kw)

    def exists(self):
        return os.path.exists(self._path)

    def is_dir(self):
        return os.path.isdir(self._path)

    def is_file(self):
        return os.path.isfile(self._path)

    def stat(self):
        return os.stat(self._path)

    def iterdir(self):
        for name in os.listdir(self._path):
            yield Path(self._path, name)

    def resolve(self):
        return Path(os.path.realpath(self._path))


class CompleteDirs:
    """Minimal CompleteDirs shim."""
    def __init__(self, root):
        self._root = root

    def open(self, *a, **kw):
        return open(self._root, *a, **kw)

    def __truediv__(self, other):
        return Path(self._root, other)


def cached_root/bower_cache_dir(cache_dir):
    return Path(cache_dir)


def fast_scan(root):
    return Path(root)


# Register in sys.modules so 'from zipfile import _path' works.
this = sys.modules[__name__]
this.Path = Path
this.CompleteDirs = CompleteDirs
this.cached_root = cached_root
this.fast_scan = fast_scan
