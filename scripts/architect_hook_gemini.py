#!/usr/bin/env python3
"""
Gemini CLI hook wrapper for Architect notifications.

Gemini hooks receive JSON via stdin and must output JSON to stdout.
This wrapper consumes stdin, calls architect_notify.py, and returns valid JSON.
"""

import json
import os
import sys
import subprocess


def main() -> int:
    try:
        # Read and consume hook input from stdin (Gemini requirement)
        try:
            hook_input = sys.stdin.read()
            if hook_input:
                json.loads(hook_input)  # Validate it's JSON
        except Exception:
            pass  # Ignore parse errors, just consume stdin

        # Get state from command-line argument
        if len(sys.argv) < 2:
            print(json.dumps({"decision": "allow"}))
            return 0

        state = sys.argv[1]

        # Call architect_notify.py script
        script_path = os.path.join(os.path.dirname(__file__), "architect_notify.py")
        subprocess.run(
            ["python3", script_path, state],
            check=False,
            capture_output=True,
        )

        # Return success JSON to Gemini (required)
        print(json.dumps({"decision": "allow"}))
        return 0

    except Exception:
        # Return success even on error to not block Gemini
        print(json.dumps({"decision": "allow"}))
        return 0


if __name__ == "__main__":
    sys.exit(main())
