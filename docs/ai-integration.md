# AI Assistant Integration

Architect exposes a Unix domain socket to let external tools (Claude Code, Codex, Gemini CLI, etc.) signal UI states.

## Socket Protocol

- Socket: `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock`
- Per-shell env vars: `ARCHITECT_SESSION_ID` (0-based) and `ARCHITECT_NOTIFY_SOCK` (socket path)
- Payload: send a single-line JSON object

Examples:
```json
{"session": 0, "state": "start"}
{"session": 0, "state": "awaiting_approval"}
{"session": 0, "state": "done"}
```

## Claude Code Hooks

1. Copy the helper script:
   ```bash
   cp scripts/architect_notify.py ~/.claude/architect_notify.py
   chmod +x ~/.claude/architect_notify.py
   ```

2. Add hooks to `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 ~/.claude/architect_notify.py done || true"
             }
           ]
         }
       ],
       "Notification": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 ~/.claude/architect_notify.py awaiting_approval || true"
             }
           ]
         }
       ]
     }
   }
   ```

## Codex Hooks

1. Copy the helper script:
   ```bash
   cp scripts/architect_notify.py ~/.codex/architect_notify.py
   chmod +x ~/.codex/architect_notify.py
   ```

2. Add the `notify` setting to `~/.codex/config.toml`:
   ```toml
   notify = ["python3", "/Users/your-username/.codex/architect_notify.py"]
   ```

## Gemini CLI Hooks

1. Copy the notification scripts:
   ```bash
   cp scripts/architect_notify.py ~/.gemini/architect_notify.py
   cp scripts/architect_hook_gemini.py ~/.gemini/architect_hook.py
   chmod +x ~/.gemini/architect_notify.py ~/.gemini/architect_hook.py
   ```

2. Add hooks to `~/.gemini/settings.json`:
   ```json
   {
     "hooks": {
       "AfterAgent": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "architect-completion",
               "type": "command",
               "command": "python3 ~/.gemini/architect_hook.py done",
               "description": "Notify Architect when task completes"
             }
           ]
         }
       ],
       "Notification": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "architect-approval",
               "type": "command",
               "command": "python3 ~/.gemini/architect_hook.py awaiting_approval",
               "description": "Notify Architect when waiting for approval"
             }
           ]
         }
       ]
     },
     "tools": {
       "enableHooks": true
     }
   }
   ```
