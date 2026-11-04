# Design: MCP tools for driving interactive agents

**Date:** 2026-11-04
**Status:** Implemented; open questions listed at the end. Tool reference: [`docs/ai-integration.md`](../../ai-integration.md)

## Goal

Let an external orchestrator run interactive coding agents (Claude Code, Codex,
Gemini CLI) inside Architect terminals and drive them turn by turn: deliver a
message, learn when the turn is over, and close the session when the work is
done. `spawn_session` already creates the terminal; nothing else exists today.

The motivating client is Mu, which currently runs one `claude -p` /
`codex exec` process per chat message. The tools must stay generic: Architect
knows about terminals, agents, and agent hooks, never about chat rooms, tasks,
or any particular orchestrator.

## Non-goals

- Reading agent replies. Agents already have their own reply channels (the
  orchestrator's CLI, native session transcripts). Scraping a TUI screen for
  the "final answer" is fragile and agent-specific.
- Queueing or scheduling messages inside Architect. Delivery policy belongs to
  the orchestrator.
- Persisting orchestrator labels or session identity across Architect restarts
  (see open questions).

## Delivery model

An idle interactive agent sits at its prompt, reading the PTY. Architect owns
the PTY master, so "waking" the agent is the same act as a user typing: write
the message as a bracketed paste and press Enter. No agent-side integration is
needed to receive input.

What the orchestrator lacks is *when*: it must not type into an agent that is
mid-turn or showing a permission prompt, and it must know when its turn ended.
Architect already receives that signal: the agent hooks installed by
`architect hook claude|codex|gemini` report `done` (turn finished) and
`awaiting_approval` over the notification socket. This design turns those
notifications into a per-session **agent state** with a monotonically
increasing **state sequence number**, and exposes it through a blocking wait.

```
orchestrator                 architect-mcp            Architect app
    | wait_for_session(until idle) ----------------->  parks the wait on the
    |                                                  control thread
    |                                      agent hook: "done" -> state idle, seq 41
    | <------------------------------ matched, idle, seq 41
    | send_input(text, require_idle) ---------------->  main thread checks idle,
    |                                                  pastes + Enter, state working, seq 42
    | <------------------------------ sent, seq 42
    | wait_for_session(until idle, after_seq 42) ---->  parked ...
    |                                      agent hook: "done" -> idle, seq 43
    | <------------------------------ matched, idle, seq 43
```

### Agent state

| State | Entered when |
| --- | --- |
| `unknown` | The session spawned (or restarted) and no agent signal arrived yet |
| `working` | `send_input` delivered text, or a hook sent `start` |
| `awaiting_approval` | A hook sent `awaiting_approval` while the agent was not idle |
| `idle` | A hook sent `done` |
| `exited` | The shell process died, or the session was closed |

Every transition gets the next value of one app-wide counter, so
`after_seq` comparisons are unambiguous across sessions and restarts of a
slot.

Claude Code's `Notification` hook fires both for permission prompts and for its
"waiting for your input" reminder about a minute after a turn ends. Both reach
Architect as `awaiting_approval`. A reminder can only arrive while the agent is
idle and a permission prompt only while it is working, so an `awaiting_approval`
received in the `idle` state leaves the state unchanged. Without this rule an
idle agent would look blocked a minute after every turn and `require_idle`
deliveries would fail.

The state is only as good as the hooks. Without hooks a session stays
`unknown`/`working` forever; the tools still work, but waiting for `idle` times
out. Typing directly into a managed terminal is not observed unless a hook
reports `start` (see open questions).

Building this exposed a race in the notification listener: it read right
after `accept` and dropped the connection when the hook client had not written
yet. The hook clients ignore send errors, so a `done` could vanish silently and
a waiter would hang until its timeout. The listener now reads with a deadline
until newline or EOF.

### Where the wait lives

`wait_for_session` is answered by the control-socket listener thread, not the
main thread. The main thread publishes agent state into a mutex-guarded board
and signals the listener's wake pipe on every change; the listener keeps
parked waits as open connections, adds their fds to its `poll(2)` set, uses the
earliest deadline as the poll timeout, and answers each wait when the board
satisfies it, the deadline passes, or the client disconnects. A parked wait
costs the main loop nothing: no wakeups, no frames, no polling.

`list_sessions`, `send_input`, and `terminate_session` touch terminals, so they
use the existing pattern: the listener queues the request, posts an SDL wake
event, and blocks until the main loop completes it within the same frame.

`architect-mcp` handles one tool call at a time, like any stdio MCP server
here. A client that waits on several sessions concurrently runs one helper
process per waiter; each holds one parked connection.

## Tool contracts

All tools return MCP structured content. Failures are tool errors
(`isError: true`) with `status: "error"`, a stable `code`, and a `message`.
`session_id` is the id returned by `spawn_session` and exported to the shell as
`ARCHITECT_SESSION_ID`; ids are never reused within one Architect process.

| Tool | Arguments | Success result |
| --- | --- | --- |
| `spawn_session` | `cwd`, optional `command`, `display_name` | `status: "spawned"`, `session_id`, `slot_index` (unchanged) |
| `list_sessions` | none | `status: "ok"`, `sessions[]` of `session_id`, `slot_index`, `cwd`, `foreground_agent`, `agent_state`, `state_seq` |
| `send_input` | `session_id`, `text`, optional `submit` (default `true`), `require_idle` (default `false`) | `status: "sent"`, `session_id`, `state_seq`, `bracketed_paste` |
| `wait_for_session` | `session_id`, `until` (non-empty list of states), optional `after_seq`, `timeout_ms` (default 30000, max 600000) | `status: "matched"`, `"exited"`, or `"timed_out"`, with `session_id`, `agent_state`, `state_seq` |
| `terminate_session` | `session_id` | `status: "terminated"`, `session_id` |

Semantics:

- `send_input` encodes `text` exactly like a user paste (ghostty's paste
  encoder strips control characters that could end a bracketed paste early),
  then appends Enter when `submit` is true. With `require_idle`, the state check
  and the write happen atomically on the main thread, so two orchestrators
  cannot both deliver into the same idle turn. If the terminal has not enabled
  bracketed paste, multi-line text is rejected with `input_not_ready` because
  each newline would submit a separate line.
- `wait_for_session` matches when the session's state is in `until` and its
  `state_seq` is greater than `after_seq` (default: any). `timeout_ms: 0`
  returns the current state immediately. An `exited` session ends every wait:
  `matched` if `until` contains `exited`, otherwise `exited`. A timeout is a
  normal result, not an error.
- `terminate_session` closes the terminal exactly like closing the tile: the
  shell gets SIGTERM, the PTY closes, and the agent receives SIGHUP. The grid
  compacts the same way.

Error codes added to the existing set: `session_not_found`, `session_exited`,
`session_busy` (`require_idle` failed), `input_not_ready`, `too_many_waiters`
(more than 64 parked waits).

## Per-conversation context

An interactive agent process holds one model context. Architect cannot split
it, and should not try: the orchestrator owns the mapping from its
conversations to agent sessions. The orchestrator spawns one Architect session
per (agent, conversation) and starts the agent with its native session id:

- first turn: `exec claude --session-id <uuid> '<first message>'` or
  `exec codex '<first message>'`
- later Architect sessions for the same conversation:
  `exec claude --resume <uuid>` / `exec codex resume <id>`

`exec` makes the agent the terminal's main process, so an agent exit ends the
session and wakes waiters with `exited`. The cost: foreground-agent detection
looks for an agent job under the shell, so `list_sessions` reports
`foreground_agent: null` for an `exec`-started agent. Per-conversation environment
(`MU_CONVERSATION_ID=... exec claude ...`) rides on the same command text.

## How Mu maps its runner onto the tools

| Mu runner today | With Architect |
| --- | --- |
| New `claude -p`/`codex exec` per message, `--resume` by `sessionIds[conversation]` | One Architect session per agent and conversation, started once with `spawn_session` (`command` as above); Mu stores `architect_session_id` next to the native session id |
| Write the prompt to the child's stdin | `wait_for_session(until: ["idle"], timeout_ms: …)`, then `send_input(text, require_idle: true)`; retry on `session_busy` |
| Wait for the child to exit | `wait_for_session(until: ["idle", "awaiting_approval"], after_seq: <seq from send_input>)`; `awaiting_approval` means a human is needed in Architect |
| Parse the final text from stream-json | Not provided by Architect: the agent replies with the Mu CLI itself (as the manual adapter already does), or Mu reads the native transcript |
| `stop(id)` kills the process group | `terminate_session` for each of the agent's Architect sessions |
| Runner restart | `list_sessions` to re-check stored ids; a missing id means the session is gone and must be re-spawned with `--resume` |

## Rejected alternatives

- **Architect-side delivery queue ("deliver when idle").** Architect would hold
  messages and paste them on the next `done`. It hides orchestration policy and
  state in the terminal app, and failures (session died before delivery)
  surface asynchronously with no caller to report to. Wait-then-send with an
  atomic `require_idle` gives the same safety with one owner of the queue.
- **Polling from `architect-mcp`.** The helper could implement the wait by
  calling a status tool every few hundred milliseconds. Each call wakes the
  app's main loop; a few always-waiting orchestrated agents would keep an
  otherwise idle Architect busy, against the change-driven frame scheduling.
- **One thread per control connection.** Simplest way to block on a wait, but
  breaks the bounded background-thread model and needs its own limits. The
  listener already has a `poll(2)` loop that can hold parked connections.
- **MCP server notifications / subscriptions.** `architect-mcp` is a
  per-client stdio process, and MCP clients do not uniformly surface server
  notifications as events that start work. A blocking tool call works with
  every client, including plain JSON-RPC scripts.
- **Idle detection from output quiescence or screen contents.** Agents stream,
  pause, and redraw unpredictably; hooks are the agents' own definition of a
  finished turn.
- **Per-conversation contexts inside one Architect session** (for example
  `/clear` and `--resume` in the same TUI). Switching contexts in a live TUI
  races with in-flight turns, loses scrollback per conversation, and couples
  Architect to each agent's slash commands.

## Open questions

1. Should `architect hook claude` also install `UserPromptSubmit → architect
   notify start`, so manual typing marks the agent `working` and `require_idle`
   is accurate even when a human interacts with a managed terminal?
2. Should `terminate_session` offer a graceful mode that sends the agent's exit
   sequence first (as quit teardown does) before closing the terminal?
3. Architect restores terminals after a restart with new session ids. Should
   `spawn_session` accept a client label that `list_sessions` returns and
   persistence keeps, so an orchestrator can re-attach instead of re-spawning?
