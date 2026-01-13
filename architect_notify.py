#!/usr/bin/env python3
"""
Architect notification helper for Codex / Claude Code / Gemini.

Accepts either a simple state argument or a Codex/Gemini JSON payload and
forwards the corresponding Architect state over the per-session Unix
socket.

Usage examples:
    architect_notify.py start
    architect_notify.py awaiting_approval
    architect_notify.py done
    architect_notify.py '{"type":"agent-turn-complete","thread-id":"..."}'
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


VALID_STATES = {"start", "awaiting_approval", "done"}


def state_from_notification(raw: str) -> str | None:
    raw = raw.strip()
    if not raw:
        return None

    if raw in VALID_STATES:
        return raw

    try:
        payload = json.loads(raw)
    except Exception:
        return None

    if not isinstance(payload, dict):
        return None

    state_field = payload.get("state")
    if isinstance(state_field, str) and state_field in VALID_STATES:
        return state_field

    status = payload.get("status")
    if isinstance(status, str):
        lowered = status.lower()
        if lowered in VALID_STATES:
            return lowered
        if lowered in ("complete", "completed", "finished", "success"):
            return "done"
        if "approval" in lowered or "permission" in lowered:
            return "awaiting_approval"

    ntype = str(payload.get("type") or "").lower()
    if ntype:
        if ntype in VALID_STATES:
            return ntype
        if "approval" in ntype or "permission" in ntype or ("input" in ntype and "await" in ntype):
            return "awaiting_approval"
        if "complete" in ntype or ntype.endswith("-done"):
            return "done"
        if "start" in ntype or "begin" in ntype:
            return "start"

    return None


def warn_unmapped(raw: str) -> None:
    if sys.stderr.isatty():
        print(f"Ignoring unmapped notification: {raw}", file=sys.stderr)


if __name__ == "__main__":
    raw_arg = sys.argv[1] if len(sys.argv) >= 2 else sys.stdin.read()
    if not raw_arg.strip():
        print(__doc__)
        sys.exit(1)

    state = state_from_notification(raw_arg)
    if state is None:
        warn_unmapped(raw_arg)
        sys.exit(0)

    notify_architect(state)
