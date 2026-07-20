#!/usr/bin/env python3
"""Spawn a session in a running Architect instance via the control socket.

Usage:
    spawn_session.py <cwd> [command] [display_name]

Finds the control socket of the newest running instance (honoring $HOME, so
point HOME at the instance's home when testing an isolated instance).
"""
import glob
import json
import os
import sys


def find_socket():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if runtime_dir is None:
        runtime_dir = os.path.join(
            os.environ["HOME"], "Library", "Caches", "Architect", "runtime"
        )
    socks = glob.glob(os.path.join(runtime_dir, "architect_control_*.sock"))
    if not socks:
        raise SystemExit(f"no control socket found in {runtime_dir}")
    return max(socks, key=os.path.getmtime)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    req = {"cwd": sys.argv[1]}
    if len(sys.argv) > 2:
        req["command"] = sys.argv[2]
    if len(sys.argv) > 3:
        req["display_name"] = sys.argv[3]

    import socket

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(find_socket())
    s.sendall((json.dumps(req) + "\n").encode())
    print(s.recv(4096).decode().strip())


if __name__ == "__main__":
    main()
