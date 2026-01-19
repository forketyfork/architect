# CLAUDE.md

Guidance for any code agent working on the Architect repo. Keep this file instruction-oriented—refer to `README.md` for product details.

## Documentation

- Architecture overview lives in `docs/architecture.md`. Read it to understand the app architecture.
- Configuration reference lives in `docs/configuration.md`. Consult it for config.toml and persistence.toml structure.

## Quick Workflow
1. Read the task and skim `README.md` for expected behavior; avoid duplicating that content here.
2. Ghostty is fetched via Zig package manager; run `just setup` only if you want to pre-cache the tarball before building.
3. Work inside the dev shell: `nix develop` (or `direnv allow`).
4. Prefer repo-friendly tools: `rg`/`fd` for search, `fastmod` or `sg` for refactors, `tree` for structure, `date` for timestamps, `gh` for PR/comment context.
5. For Zig changes, use the `zig-best-practices` skill; if it is not installed, install it via the skill installer before editing.

## Coding Conventions
- Favor self-documenting code; keep comments minimal and meaningful.
- Default to ASCII unless the file already uses non-ASCII.
- **Error handling**: Always handle errors explicitly—propagate, recover, or log. Never use bare `catch {}` or `catch unreachable`. Even for "impossible" failures like action queue appends, log them:
  ```zig
  // WRONG: silently swallows the error
  actions.append(.SomeAction) catch {};

  // CORRECT: log the error for debugging
  actions.append(.SomeAction) catch |err| {
      log.warn("failed to queue action: {}", .{err});
  };
  ```
- Run `zig fmt src/` (or `zig fmt` on touched Zig files) before wrapping up changes.
- Avoid destructive git commands and do not revert user changes.

## Git Workflow
When creating a new feature or fix branch:
1. Always start from an up-to-date `main` branch
2. Pull the latest changes: `git checkout main && git pull origin main`
3. Create your branch from main: `git checkout -b <branch-name>`
4. Never create branches from other feature branches unless explicitly intended

This ensures PRs are based on the latest code and avoids unrelated changes in your PR.

**Working in git worktrees:**
If you are executing in a git worktree, stay within that worktree and do not attempt to access the root repository directory. All your work should remain in the worktree's local directory structure.

## SDL3 Usage Notes

### Window-close handling on macOS
- When you handle Cmd+W yourself, set `SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE` to `"0"` so SDL does not emit `SDL_EVENT_QUIT` and bypass your custom close logic.

### Adding New SDL3 Key Codes
When adding references to SDL3 key codes (SDLK_*) or other SDL constants, always add them to `src/c.zig` first instead of searching the web for their values. SDL3 constants are exposed through the c_import and must be explicitly re-exported in c.zig to be accessible throughout the codebase.

**Pattern:**
```zig
// In src/c.zig, after existing SDLK_* exports:
pub const SDLK_NEWKEY = c_import.SDLK_NEWKEY;
```

This applies to all SDL3 constants: key codes (SDLK_*), modifier flags (SDL_KMOD_*), event types (SDL_EVENT_*), etc.

## Zig Language Gotchas

### Type Inference with Builtin Functions
**Problem:** Zig's builtin functions like `@min`, `@max`, and `@clamp` infer result types from their operands. When both operands include small comptime constants, the result type can be unexpectedly narrow. If subsequent arithmetic also uses comptime constants, the entire expression stays in the narrow type and can overflow.

**Example Bug:**
```zig
const GRID_COLS = 3;  // comptime_int (not usize!)
const GRID_ROWS = 3;

// @min infers u2 from the comptime constant (GRID_COLS - 1 = 2)
const grid_col = @min(@as(usize, col_index), GRID_COLS - 1);  // u2
const grid_row = @min(@as(usize, row_index), GRID_ROWS - 1);  // u2

// WRONG: entire expression stays u2 because GRID_COLS is comptime_int
const result = grid_row * GRID_COLS + grid_col;
// 1 * 3 + 2 = 5, but u2 max is 3 → panic in debug, wraps to 1 in release!
```

**Solution:** Use explicit `: usize` annotation to force the result type:
```zig
const GRID_COLS = 3;
const GRID_ROWS = 3;

// Explicit usize annotation prevents narrow type inference
const grid_col: usize = @min(@as(usize, col_index), @as(usize, GRID_COLS - 1));
const grid_row: usize = @min(@as(usize, row_index), @as(usize, GRID_ROWS - 1));
const result = grid_row * GRID_COLS + grid_col;  // usize, works correctly
```

**When to be careful:**
- Using `@min`, `@max`, `@clamp` with comptime integer literals or constants
- Subsequent arithmetic with comptime constants (they peer-resolve with narrow types)
- Index calculations for grids or arrays

**General rule:** When calculating indices or sizes, add explicit `: usize` type annotations to `@min`/`@max` results.

### Naming collisions in large render functions
- When hoisting shared locals (e.g., `cursor`) to wider scopes inside long functions, avoid re-declaring them later with the same name. Zig treats this as shadowing and fails compilation. Prefer a single binding per logical value or choose distinct names for nested scopes to prevent “local constant shadows” errors.

### Zig 0.15 collection API differences
- `std.ArrayList(T)` now prefers `initCapacity(allocator, 0)`; `append` and similar methods require the allocator argument (`list.append(allocator, item)`).
- `std.fmt.allocPrintZ` is unavailable; create a null-terminated buffer manually: allocate `len+1`, copy bytes, set the last byte to 0, and slice as `buf[0..len :0]`.
- For writers, `toml.serialize` expects `*std.Io.Writer`. Use `std.Io.Writer.Allocating.init(allocator)` (or `initCapacity`) and pass `&writer.writer`; read bytes with `writer.written()`.

## Build and Test (required after every task)
- Run `zig build` and `zig build test` (or `just ci` when appropriate) once the task is complete.
- Report the results in your summary; if you must skip tests, state the reason explicitly.

## Documentation Hygiene (REQUIRED)
- **ALWAYS** update documentation when making changes. This is not optional.
- Update `README.md` for any user-facing changes: new features, configuration options, keyboard shortcuts, or behavior changes.
- Update `docs/architecture.md` when adding new components, modules, or changing the system structure.
- Update `docs/configuration.md` when adding, removing, or changing configuration options in `config.toml` or `persistence.toml`.
- Keep this `CLAUDE.md` aligned when workflows or automation expectations change.
- Documentation updates should be part of the same PR as the code changes.

## Repo Notes
- Architect is a Zig app using the ghostty-vt dependency fetched via the Zig package manager; avoid reintroducing a checked-out `ghostty/` path assumption.
- User config lives in `~/.config/architect/config.toml`. Maintain compatibility or add migrations when changing config shape.
- `just` commands mirror zig builds (`just build`, `just run`, `just test`, `just ci`); use them when adjusting CI scripts or docs.
- Shells spawn as login shells (`zsh -l`), so login profiles (`/etc/zprofile`, `~/.zprofile`) are sourced; nix-darwin `environment.shellAliases` end up in the generated `/etc/zprofile`, which is the place to check when aliases or env values are missing inside Architect.
- Shared UI/render utilities live in `src/geom.zig` (Rect + point containment), `src/anim/easing.zig` (easing), and `src/gfx/primitives.zig` (rounded/thick borders); reuse them instead of duplicating helpers.
- The UI overlay pipeline is centralized in `src/ui/`—`UiRoot` receives events before `main`’s switch, runs per-frame `update`, drains `UiAction`s, and renders after the scene; register new components there rather than adding more UI logic to `main.zig`.
- Reusable marquee text rendering lives in `src/ui/components/marquee_label.zig`; use it instead of re-implementing scroll logic.
- Cursor rendering: set the cursor’s background color during the per-cell background pass and render the glyph on top; avoid drawing a separate cursor rectangle after text rendering, which hides the underlying glyph.
- ghostty-vt defaults: `Terminal.Options.max_scrollback` is 10_000 bytes and `0` disables scrollback entirely; set it explicitly when you expect deeper history. Ghostty’s app sets 10 MB via `scrollback-limit` in Config.zig; upstream currently doesn’t support unlimited scrollback. Use bytes, not lines, when sizing scrollback.

## Architecture Invariants (agent instructions)
- Route UI input/rendering through `UiRoot` only; do not add new UI event branches or rendering in `main.zig` or `renderer.zig`.
- Keep scene rendering (`renderer.zig`) focused on terminals/scene overlays; UI components belong in `src/ui/components/` and render after `renderer.render(...)`.
- Do not store UI state or UI textures in session structs or `app_state.zig`; UI state must live inside UI components or UI-managed assets.
- Add new UI features by registering components with `UiRoot`; never bypass `UiAction` for UI→app mutations.
- When a UI component moves into a new visible state (modals expanding, toasts appearing, gesture indicators starting), use `src/ui/first_frame_guard.zig`: call `markTransition()` when the state flips and `markDrawn()` at the end of the first render; have `wantsFrame` return `guard.wantsFrame()` so the main loop renders immediately even under idle throttling.
- Restored terminals use `SessionState.ensureSpawnedWithDir` to launch shells already in the target directory; changing cwd of a live shell is not supported—spawn or restart with the desired path.

## Rendering & Unicode Notes
- Only read `cell.content.codepoint` when `content_tag == .codepoint`; palette-only or non-text cells should render as empty. Misreading other tags produces spurious replacement glyphs.
- Sanitize incoming codepoints before shaping: replace surrogates or values above `0x10_FFFF` with U+FFFD to prevent `utf8CodepointSequenceLength` errors from malformed TTY/OSC output.

## Known Pitfalls
- Session teardown can run twice on error paths (errdefer plus outer defer). Keep `SessionState.deinit` idempotent: destroy textures/fonts/watchers, then null pointers and reset flags; in `main.zig` only deinit sessions that were actually constructed.
- Running `rg` over the whole $HOME on macOS hits protected directories and can hang/time out; narrow searches to the repo, `/etc`, or specific config paths to avoid permission noise and delays.
- Do not keep TOML parser-owned maps after `result.deinit()`: duplicate keys and values into your own storage before freeing the parser arena, or later iteration will segfault.
- `std.mem.span` rejects `[:0]const u8` slices; use `std.mem.sliceTo(ptr, 0)` for `[:0]const u8`, and use `std.mem.span` for `[*c]const u8`/`[*:0]const u8` C pointers.
- When copying persisted maps (e.g., `[terminals]`), duplicate both key and value slices; borrowing the parser’s backing memory causes use-after-free crashes.
- Terminal cwd persistence is currently macOS-only; other platforms skip saving/restoring terminals to avoid stale directories until cross-platform cwd tracking is implemented.
- xev process watchers keep a pointer to the provided userdata; if you reuse a shared struct for multiple spawns, a late callback can read updated fields and wrongly mark a new session dead. Allocate a per-watcher context, free it on teardown or after the callback, and bump a generation counter on spawn/despawn to ignore stale events.
- Restart buttons should only render when a session is both `spawned` and `dead`; broader checks can surface controls for never-spawned slots.

## Claude Socket Hook
- The app creates `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock` and sets `ARCHITECT_SESSION_ID`/`ARCHITECT_NOTIFY_SOCK` for each shell.
- Send a single JSON line to signal UI states: `{"session":N,"state":"start"|"awaiting_approval"|"done"}`. The helper `scripts/architect_notify.py` is available if needed.

## Done? Share
- Provide a concise summary of edits, test/build outcomes, and documentation updates.
- Suggest logical next steps only when they add value.
