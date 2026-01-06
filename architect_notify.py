#!/usr/bin/env python3
"""
Architect notification helper for Claude Code.

Sends state updates to Architect's Unix domain socket when running
inside an Architect terminal session.

Usage:
    architect_notify.py start              # Clear highlight, mark running
    architect_notify.py awaiting_approval  # Show pulsing yellow border (request)
    architect_notify.py done               # Show solid green border (completion)
"""

import json
import os
import socket
import sys


def notify_architect(state: str) -> None:
    session_id = os.environ.get("ARCHITECT_SESSION_ID")
    sock_path = os.environ.get("ARCHITECT_NOTIFY_SOCK")

    if not session_id or not sock_path:
        return

    try:
        message = json.dumps({
            "session": int(session_id),
            "state": state
        }) + "\n"

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sock_path)
        sock.sendall(message.encode())
        sock.close()
    except Exception:
        pass


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)

    state = sys.argv[1]
    if state not in ["start", "awaiting_approval", "done"]:
        print(f"Invalid state: {state}")
        print("Valid states: start, awaiting_approval, done")
        sys.exit(1)

    notify_architect(state)
