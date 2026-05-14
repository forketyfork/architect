# AI Assistant Integration

Architect exposes a Unix domain socket to let external tools (Claude Code, Codex, Gemini CLI, etc.) signal UI states.

Architect also ships `architect-mcp`, a separate stdio MCP helper that lets local MCP clients ask the running app to create new terminal sessions.

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

## MCP `spawn_session`

`architect-mcp` is launched by an MCP client as a stdio server. It exposes exactly one tool, `spawn_session`, and forwards each call to the running Architect app through a local Unix-domain control socket. The helper is not a daemon and does not launch the GUI app if Architect is not already running.

The running app writes a per-instance discovery file named `architect_control_<uid>_<pid>.json` under `XDG_RUNTIME_DIR` when that is set. Otherwise it uses a stable per-user runtime directory: `~/Library/Caches/Architect/runtime` on macOS, or `~/.cache/architect/runtime` on other platforms. The app logs the full discovery file path together with the socket path. When several Architect instances are running, `architect-mcp` tries the newest reachable discovery entry.

Helper paths:

- Source builds: `zig-out/bin/architect-mcp`
- Release app bundle: `Architect.app/Contents/MacOS/architect-mcp`
- Homebrew: `architect-mcp` on `PATH`, with the app-bundle path under `$(brew --prefix)/Cellar/architect/<version>/Architect.app/Contents/MacOS/architect-mcp` as a fallback

Input schema:

```json
{
  "type": "object",
  "required": ["cwd"],
  "additionalProperties": false,
  "properties": {
    "cwd": {
      "type": "string",
      "description": "Absolute working directory for the new terminal session."
    },
    "command": {
      "type": "string",
      "description": "Optional command text queued into the new shell. Architect appends a newline when needed."
    },
    "display_name": {
      "type": "string",
      "description": "Optional display label reserved for clients and future Architect UI."
    }
  }
}
```

Example tool arguments:

```json
{
  "cwd": "/Users/me/dev/project",
  "command": "codex",
  "display_name": "Project task"
}
```

Successful calls return MCP structured content like:

```json
{
  "status": "spawned",
  "session_id": 12,
  "slot_index": 3
}
```

Tool errors use stable codes:

- `invalid_request`: the MCP arguments do not match the schema
- `app_not_running`: no running Architect app accepted the local control request
- `full_grid`: every Architect terminal slot is already in use
- `invalid_cwd`: `cwd` is not an absolute existing directory
- `spawn_failed`: Architect accepted the request but could not create or initialize the terminal session

## Built-in Command (inside Architect terminals)

Architect injects a small `architect` command into each shell's `PATH`. It reads the
session id and socket path from the environment, so hooks can simply call:

```bash
architect notify start
architect notify awaiting_approval
architect notify done
```

On macOS zsh login shells, `/etc/zprofile` resets `PATH` via `path_helper`. Architect
adds wrapper files at `~/.cache/architect/zsh/.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin`
that source your original dotfiles, prepend the Architect command directory, and install
a small guard so `PATH` keeps the Architect entry after directory changes.

If your hook runs outside an Architect terminal, use the Python helper scripts below.
Replace `architect notify ...` in the examples with `python3 ~/.<tool>/architect_notify.py ...` when using those scripts.

## Hook Installer

From inside an Architect terminal, you can install hooks automatically:

```bash
architect hook claude
architect hook codex
architect hook gemini
```

If you upgrade Architect, restart existing terminals so the bundled `architect` script refreshes.
The installer writes timestamped backups before updating configs (for example:
`settings.json.architect.bak.20260127T153045Z`).

## Claude Code Hooks

1. (Optional) Copy the helper script if the hook runs outside Architect:
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
               "command": "architect notify done || true"
             }
           ]
         }
       ],
       "Notification": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "architect notify awaiting_approval || true"
             }
           ]
         }
       ]
     }
   }
   ```

## Codex Hooks

1. (Optional) Copy the helper script if the hook runs outside Architect:
   ```bash
   cp scripts/architect_notify.py ~/.codex/architect_notify.py
   chmod +x ~/.codex/architect_notify.py
   ```

2. Add the `notify` setting to `~/.codex/config.toml`:
   ```toml
   notify = ["architect", "notify"]
   ```

If you already have `notify` configured, `architect hook codex` overwrites it,
prints a warning, and prints the backup file name.

## Gemini CLI Hooks

Gemini hooks must emit JSON to stdout, so keep using the wrapper script even inside
Architect terminals (it can call `architect notify` under the hood).

1. Copy the notification scripts (the `architect hook gemini` installer assumes they exist):
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
