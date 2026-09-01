#!/usr/bin/env python3
"""Wrapper that captures yt-dlp output to a log file.

Called as: python3 _ytdlp_wrapper.py <log_path> <yt-dlp_script> [args...]
"""
import os, sys

def main():
    if len(sys.argv) < 3:
        print("Usage: _ytdlp_wrapper.py <log_path> <script> [args...]", file=sys.stderr)
        sys.exit(1)

    log_path = sys.argv[1]
    script = sys.argv[2]
    # sys.argv[0] = wrapper, sys.argv[1] = log_path, sys.argv[2] = script, rest = yt-dlp args
    sys.argv = [script] + sys.argv[3:]

    # Redirect fd 1 and 2 to the log file (reliable, bypasses Python buffering).
    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    os.close(log_fd)

    # Also set Python-level stdout/stderr.
    sys.stdout = os.fdopen(1, 'w', buffering=1)
    sys.stderr = os.fdopen(2, 'w', buffering=1)

    # Run yt-dlp via run_path.
    import runpy
    try:
        runpy.run_path(script, run_name='__main__')
    except SystemExit:
        pass

if __name__ == '__main__':
    main()
