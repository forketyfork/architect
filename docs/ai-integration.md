# AI Assistant Integration

Architect exposes a Unix domain socket to let external tools (Claude Code, Codex, Gemini CLI, etc.) signal UI states.

Architect also ships `architect-mcp`, a separate stdio MCP helper that lets local MCP clients and orchestrators create terminal sessions, deliver messages to the agents running in them, wait for their turns to end, and close them.

## Socket Protocol

- Socket: `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock`
- Per-shell env vars: `ARCHITECT_SESSION_ID` (0-based) and `ARCHITECT_NOTIFY_SOCK` (socket path)
- Payload: send a single-line JSON object

Examples:
```json
{"session": 0, "state": "start"}
{"session": 0, "state": "awaiting_approval"}
{"session": 0, "state": "done"}
{"session": 0, "state": "ready"}
```

## MCP tools

`architect-mcp` is launched by an MCP client as a stdio server and forwards each tool call to the running Architect app through a local Unix-domain control socket. The helper is not a daemon and does not launch the GUI app if Architect is not already running. It answers one call at a time, so a client that waits on several sessions concurrently runs one helper per waiter.

The running app writes a per-instance discovery file named `architect_control_<uid>_<pid>.json` under `XDG_RUNTIME_DIR` when that is set. Otherwise it uses a stable per-user runtime directory: `~/Library/Caches/Architect/runtime` on macOS, or `~/.cache/architect/runtime` on other platforms. The app logs the full discovery file path together with the socket path. Each running app also has an `instance_id`, published in its discovery file and returned by every tool. Session ids restart at 0 in every app, so a session is identified by the pair (`instance_id`, `session_id`): `send_input`, `wait_for_session`, and `terminate_session` require both and only ever reach that instance, failing with `instance_not_found` when it is no longer running instead of trying another app. This holds across separate `architect-mcp` processes too. `spawn_session` and `list_sessions` accept an optional `instance_id`; without one they go to the newest reachable instance.

Helper paths:

- Source builds: `zig-out/bin/architect-mcp`
- Release app bundle: `Architect.app/Contents/MacOS/architect-mcp`
- Homebrew: `architect-mcp` on `PATH`, with the app-bundle path under `$(brew --prefix)/Cellar/architect/<version>/Architect.app/Contents/MacOS/architect-mcp` as a fallback

`tools/list` returns the exact JSON schemas. All results are MCP structured content with a `status` field; failures are tool errors (`isError: true`) with `status: "error"`, a stable `code`, and a `message`.

### Agent state

Each session has an `agent_state` and a `state_seq`. `state_seq` comes from one app-wide counter that increases on every change, so "a change after the one I saw" is `state_seq > after_seq`.

| `agent_state` | Meaning |
| --- | --- |
| `unknown` | No agent signal since the session started |
| `working` | `send_input` delivered text, or a hook reported `start` |
| `awaiting_approval` | A hook reported that the agent waits for a human (for example a permission prompt) |
| `idle` | A hook reported `done` (the turn is over), or `ready` while the state was `unknown` (the agent started and waits for its first prompt) |
| `exited` | The shell process died or the session was closed |

A submitted `send_input` itself moves the state to `working` for every agent (and shows the tile as running, as a `start` hook does). The other transitions come from the hooks below (`architect hook claude|codex|gemini`); without them a session never becomes `idle`. For Claude Code the installer adds `SessionStart` → `ready`, `UserPromptSubmit` → `start`, `Stop` → `done`, and `Notification` → `awaiting_approval`; run `architect hook claude` again to add the first two to an existing setup. `ready` only matters while the state is `unknown`, because `SessionStart` also fires on `/clear` and compaction. Claude Code's `Notification` hook also fires as an idle reminder about a minute after a turn ends; Architect ignores `awaiting_approval` while the agent is `idle`, so the reminder does not make an idle agent look blocked: the agent state stays `idle`, while the tile still shows the reminder's attention highlight, as it always has. Any other hook the agent state ignores (for example `ready` arriving mid-turn after a compaction) leaves the tile unchanged too. The Codex and Gemini installers do not add `ready` or `start` yet, so a fresh Codex or Gemini session stays `unknown` until its first `done`: start it with its first message on the command line instead of delivering it with `send_input`.

### `spawn_session`

| Argument | Type | Notes |
| --- | --- | --- |
| `cwd` | string, required | Absolute existing directory |
| `command` | string, at most 1023 bytes | Typed into the new shell; Architect appends a newline when needed. The shell may still be in canonical mode when the text arrives, and macOS keeps only 1024 bytes per line there, so longer commands are rejected: put them in a script and spawn `exec /path/to/script` |
| `display_name` | string | Reserved for clients and future Architect UI |

Result: `status: "spawned"`, `instance_id`, `session_id`, `slot_index`. Store `instance_id` with the `session_id`; both are needed for every later call. `session_id` is also exported to the shell as `ARCHITECT_SESSION_ID`, and ids are never reused while the app runs.

To drive an agent, start it with `exec` (for example `exec claude --session-id <uuid>`): the agent then replaces the shell, so when it exits the session exits too and waiters see `exited`. `list_sessions` reports `foreground_agent` only for agents started as a job of the shell, so it is `null` for `exec`-started agents.

### `list_sessions`

Optional `instance_id`. Result: `status: "ok"`, `instance_id`, and `sessions`, each with `session_id`, `slot_index`, `cwd`, `foreground_agent` (`claude`, `codex`, `gemini`, or `null`), `agent_state`, and `state_seq`.

### `send_input`

| Argument | Type | Notes |
| --- | --- | --- |
| `instance_id` | string, required | From `spawn_session` or `list_sessions` |
| `session_id` | integer, required | |
| `text` | string, required | Up to 256 KiB, no NUL bytes |
| `submit` | boolean, default `true` | Press Enter after the text |
| `require_idle` | boolean, default `false` | Deliver only when `agent_state` is `idle` |

The text is encoded like a user paste: control characters that could end a bracketed paste early are replaced, and the text is wrapped in bracketed-paste markers when the terminal enabled them. With `require_idle`, the state check and the write are atomic, so two clients cannot both deliver into the same idle turn. With `submit: false` the text is typed as a draft and the state does not change. Without bracketed paste only one line (no CR or LF) of at most 1023 bytes is accepted, in both submit modes, because the program may still be in canonical mode, where macOS keeps 1024 bytes per line. Result: `status: "sent"`, `instance_id`, `session_id`, `state_seq` (the `working` state a submitted delivery recorded, or the unchanged state for a draft), and `bracketed_paste`.

### `wait_for_session`

| Argument | Type | Notes |
| --- | --- | --- |
| `instance_id` | string, required | From `spawn_session` or `list_sessions` |
| `session_id` | integer, required | |
| `until` | array of `agent_state` values, required | |
| `after_seq` | integer, default `0` | Only states with a larger `state_seq` match |
| `timeout_ms` | integer, default `30000`, max `600000` | `0` returns the current state immediately |

Result: `status` is `matched`, `exited` (the session ended and `until` does not contain `exited`), or `timed_out`, plus `instance_id`, `session_id`, `agent_state`, and `state_seq`. A timeout is a normal result. Waits are held by the app's control listener and cost the app nothing while they are pending; make sure the MCP client's own tool-call timeout is longer than `timeout_ms`.

### `terminate_session`

`instance_id` and `session_id` are required. The session closes like closing its tile: the shell gets SIGTERM, the PTY closes, and the agent receives SIGHUP. Result: `status: "terminated"`, `instance_id`, `session_id`.

### Driving an agent turn by turn

```text
spawn_session(cwd, command: "exec claude --session-id <uuid>")             -> instance I, session N
wait_for_session(I, N, until: ["idle"], timeout_ms: 60000)                -> idle (ready), seq S
send_input(I, N, text: "<first message>", require_idle: true)             -> sent, seq D
wait_for_session(I, N, until: ["idle", "awaiting_approval"], after_seq: D) -> idle: turn over
send_input(I, N, text: "<next message>", require_idle: true)              -> sent, seq E
wait_for_session(I, N, until: ["idle", "awaiting_approval"], after_seq: E) -> idle: turn over
terminate_session(I, N)
```

On `session_busy`, wait for `idle` again and retry. `awaiting_approval` means the agent needs a human in Architect. Use one session per agent conversation: an interactive agent keeps one model context per process, and resuming with the agent's own session id (`claude --resume`, `codex resume`) restores a conversation in a new session.

### Error codes

- `invalid_request`: the arguments do not match the schema
- `app_not_running`: no running Architect app accepted the local control request, or it is shutting down
- `full_grid`: every Architect terminal slot is already in use
- `invalid_cwd`: `cwd` is not an absolute existing directory
- `spawn_failed`: Architect accepted the request but could not create or initialize the terminal session
- `session_not_found`: no session has this id
- `instance_not_found`: the Architect instance named by `instance_id` is not running, or the request reached a different instance
- `session_exited`: the session's process exited or the session was closed
- `session_busy`: `require_idle` was set and the agent is not `idle`
- `input_not_ready`: the terminal cannot take the input yet, for example multi-line or over-long text before the program enabled bracketed paste
- `input_failed`: writing to the terminal failed
- `too_many_waiters`: more than 64 `wait_for_session` calls are pending
- `internal_error`: Architect failed while handling the request

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
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "architect notify ready || true"
             }
           ]
         }
       ],
       "UserPromptSubmit": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "architect notify start || true"
             }
           ]
         }
       ],
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

Codex reports finished turns only through this `notify` program, so `wait_for_session` needs it to run `architect notify` directly. A wrapper that relays to the previous `notify` program (for example the Codex Computer Use client with `--previous-notify`) did not deliver turn-complete notifications in testing.

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
