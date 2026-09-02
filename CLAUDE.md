# CLAUDE.md (symlinked as AGENTS.md)

[Canonical file: `CLAUDE.md`. Keep `AGENTS.md` as a symlink to `CLAUDE.md`.]

## Project

**Name:** Architect
**Description:** A terminal multiplexer and AI-assisted coding environment built on SDL3 and Zig. Architect lets developers run multiple terminal sessions in a tiled layout, annotate diffs, and integrate Claude agents directly into their workflow.
**Stack:** Zig 0.16, SDL3, ghostty-vt (terminal emulation), Nix dev shell, `just` task runner
**Status:** Active development

## Build & Run

```bash
# Worktree bootstrap (run in a fresh worktree)
just setup   # pre-caches the ghostty-vt tarball; skip if already cached

# Environment activation
nix develop  # or: direnv allow
#
# Minimal host prerequisites:
# - Nix with flakes enabled (or direnv + nix-direnv)
# - macOS (primary platform; Linux support is partial)

# Build
zig build

# Run
zig build run

# Test
zig build test

# Type check
N/A  # Zig build covers type checking

# Lint
just lint

# Format check
zig fmt --check src/
```

## Infrastructure

- **Source code hosting:** GitHub — URL: `https://github.com/forketyfork/architect` — CLI: `gh` — Skill: `managing-github`
- **Issue tracker:** GitHub Issues — URL: `https://github.com/forketyfork/architect/issues` — CLI: `gh issue` — Skill: `managing-github`
- **CI/CD:** GitHub Actions — config: `.github/workflows/`
- **Issue/PR linkage convention:** Reference issues in commit messages and PR descriptions using `#<issue-number>`. Use `Closes #N` or `Fixes #N` in the PR body to auto-close issues on merge.

Use the `managing-github` skill for all GitHub operations: creating issues, pull requests, fetching review threads, posting comments, and searching.

## Project Documentation

Read these before making any changes:

- `README.md` — User-facing product overview; skim for expected behavior, do not duplicate here
- `docs/ARCHITECTURE.md` — How it's built (layers, modules, dependencies)
- `docs/configuration.md` — Config shape for `config.toml` and `persistence.toml`
- `docs/development.md` — Developer setup and workflow notes
- `docs/perf-debugging.md` — Read before investigating rendering/terminal performance: headless repro via the control socket (`scripts/perf/`), codex resize behavior, Debug-vs-Release ghostty-vt costs, SDL/Metal pipeline pitfalls

## Agent Rules

1. Read the project documentation listed above before writing any code.
2. For Zig changes, use the `zig-best-practices` skill; install it via the skill installer if not available.
3. Every new feature must have corresponding tests. A new file that declares tests must also be added to the `test { _ = @import(...); }` block in `src/main.zig` — Zig only collects tests from files it analyzes, so an unregistered file's tests compile but never run. `scripts/check-test-registry.sh` (part of `just lint`) enforces this.
4. Do not introduce new dependencies without asking first.
5. If you change the architecture (new modules, new data flows), update `docs/ARCHITECTURE.md`.
6. Use conventional commit messages.
7. After making changes, verify the build, tests, and linting all pass (`zig build`, `zig build test`, `just lint`) before considering the task done.
8. Always update documentation alongside code changes (see Documentation Hygiene below).
9. Use `managing-github` skill for all GitHub interactions (issues, PRs, comments).

## Observability

### What the agent can do independently

- Run tests and see output: `zig build test`
- Build and check for compiler errors: `zig build`
- Run linting: `just lint`
- Search repo: `rg`/`fd`

### What requires developer assistance

- SDL3 window/rendering — developer must describe visual state or provide a screenshot
- Terminal emulation behavior — developer provides screen recordings or descriptions

### Debug mode

- `zig build -Doptimize=Debug` for debug builds (default)
- Add `std.log` calls at the relevant site; logs appear on stderr during `zig build run`

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

### Never render while the window is occluded
- macOS stops compositing fully covered windows and `CAMetalLayer` stops returning drawables; any render attempt then blocks the main thread for the full ~1s `nextDrawable` timeout, stalling input and PTY processing. The frame loop gates rendering on the `SDL_WINDOW_OCCLUDED` window flag (`shouldRenderFrame` in `src/app/runtime.zig`); keep any new render/present paths behind the same gate.

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
- When hoisting shared locals (e.g., `cursor`) to wider scopes inside long functions, avoid re-declaring them later with the same name. Zig treats this as shadowing and fails compilation. Prefer a single binding per logical value or choose distinct names for nested scopes to prevent "local constant shadows" errors.

### Zig 0.16 API notes
- `std.ArrayList(T)` is the unmanaged list: init with `.empty` (or `initCapacity`), and pass the allocator to each method (`list.append(allocator, item)`). `std.ArrayListUnmanaged` is a deprecated alias — do not use it.
- `std.fs` retains only `path`, `max_path_bytes`, `max_name_bytes`, and the base64 alphabets. Every filesystem operation moved to `std.Io.Dir` / `std.Io.File` and takes an `io` argument. Two irregularities to remember: `Dir.renameAbsolute(old, new, io)` takes `io` **last**, and `makeDirAbsolute`/`makePath` were renamed to `createDirAbsolute`/`createDirPath` rather than merely gaining a parameter.
- `std.time` retains only its duration constants. Timestamps come from `clock.zig`, which wraps `std.Io.Timestamp.now(io, .real)`. The clock enum tags are `real`, `awake`, `boot`, `cpu_process`, `cpu_thread`.
- `std.Thread.spawn`/`join`/`detach` survive; `std.Thread.Mutex`, `Condition`, `Pool`, `WaitGroup`, and `sleep` do not. Use `std.Io.Mutex` / `std.Io.Condition`, initialized with `.init` (not `.{}`), and prefer `lockUncancelable`/`waitUncancelable` — Architect has no cancellation model, so a fallible lock adds error paths with no correct recovery.
- `std.process.Child` keeps only `kill(io)` and `wait(io)`. Creation is `std.process.spawn(io, opts)`; the collect-output pattern is `std.process.run(gpa, io, opts)`. `Child.Term` tags are lowercase (`.exited`, `.signal`, `.stopped`, `.unknown`) and `signal` carries `std.posix.SIG`, not `u32`. Use `src/proc.zig` for the application process helpers.
- Link and include configuration lives on `std.Build.Module`, not `std.Build.Step.Compile`. `link_libc` is a Module field, settable in `b.createModule`.
- `std.posix.getenv` is gone. Read the environment through `src/env.zig`.

### Inventory greps for std API migrations
`const fs = std.fs;` and `const posix = std.posix;` aliases hide call sites from a `std.`-qualified grep — this cost real time during the 0.16 migration. Always match `\b(std\.)?fs\.` and `\b(std\.)?posix\.`. When excluding survivors, put the underscore in the character class: `fs\.[A-Za-z]+` truncates `fs.max_path_bytes` to `fs.max` and lets it slip past the filter.

### Loop boundary conditions
When iterating over slices with index arithmetic, use `< len` not `<= len`:
```zig
// WRONG: iterates one past the end, causing unnecessary work or out-of-bounds
while (pos <= slice.len) { ... }

// CORRECT: stops at the last valid position
while (pos < slice.len) { ... }
```
The `<= len` pattern is only correct when `pos` represents a position *after* processing (e.g., `slice[0..pos]` as a "processed so far" marker).

## Documentation Hygiene (REQUIRED)
- **ALWAYS** update documentation when making changes. This is not optional.
- Update `README.md` for any user-facing changes: new features, configuration options, keyboard shortcuts, or behavior changes.
- Update `docs/ARCHITECTURE.md` when adding new components, modules, or changing the system structure.
- Update `docs/configuration.md` when adding, removing, or changing configuration options in `config.toml` or `persistence.toml`.
- Keep this `CLAUDE.md` aligned when workflows or automation expectations change.
- Documentation updates should be part of the same PR as the code changes.

## Repo Notes
- Architect is a Zig app using the ghostty-vt dependency fetched via the Zig package manager; avoid reintroducing a checked-out `ghostty/` path assumption.
- User config lives in `~/.config/architect/config.toml`. Maintain compatibility or add migrations when changing config shape.
- `just` commands mirror zig builds (`just build`, `just run`, `just test`, `just ci`); use them when adjusting CI scripts or docs.
- Shells spawn as login shells (`zsh -l`), so login profiles (`/etc/zprofile`, `~/.zprofile`) are sourced; nix-darwin `environment.shellAliases` end up in the generated `/etc/zprofile`, which is the place to check when aliases or env values are missing inside Architect.
- On macOS hosts where `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` is arm64e-only, the Nix dev shell and Homebrew formula use the Zig 0.16.0 workaround: it points `DEVELOPER_DIR` at a fake developer dir backed by `MacOSX15.4.sdk` and installs an `xcrun` shim inside that fake developer tree so `zig build`, Ghostty's Apple SDK discovery, and unrelated tools that still invoke `/usr/bin/xcrun` keep working. Keep it until a macOS host confirms the upstream fix for https://codeberg.org/ziglang/zig/issues/31756 makes it unnecessary.
- Shared UI/render utilities live in `src/geom.zig` (Rect + point containment), `src/anim/easing.zig` (easing), `src/gfx/primitives.zig` (rounded/thick borders), and `src/gfx/shimmer.zig` (busy shimmer used by the quit overlay); reuse them instead of duplicating helpers.
- Performance measurements use `scripts/perf/cpu_probe.sh` on macOS, where `top -stats idlew` and `ps -M` provide CPU, idle-wakeup, and per-thread CPU-time data; use ReleaseFast builds for comparable numbers.
- The notification and control socket listeners block in `poll(2)` on their listening socket plus a `WakePipe` self-pipe (`src/wake_pipe.zig`); the PTY reader blocks on its registered master fds plus its `WakePipe`, which `register`/`retire` signal. Shutdown stores each stop flag, signals its pipe, and then joins the thread so fixed-interval polling does not create background wakeups.
- Frame scheduling lives in `src/app/frame_schedule.zig` (pure, unit-tested). Anything that changes pixels over time must report it (`wantsFrame`, `markDirty`, `UiAction`); there is deliberately no periodic re-render to fall back on.
- The UI overlay pipeline is centralized in `src/ui/`—`UiRoot` receives events before `main`'s switch, runs per-frame `update`, drains `UiAction`s, and renders after the scene; register new components there rather than adding more UI logic to `main.zig`.
- Reusable marquee text rendering lives in `src/ui/components/marquee_label.zig`; use it instead of re-implementing scroll logic.
- Any text field must store its buffer in a `text_edit.TextInput` (`src/ui/text_edit.zig`) and route key events through `handleKey` / `insert`, so every field keeps the same macOS behavior: blinking caret, Backspace (⌘ clears / ⌥ word / plain one UTF-8 codepoint), ⌘A, ⌘C, ⌘V. Configure it per field with `separators` (`name_separators`, `path_separators`, `prose_separators`), `max_len`, and `accepts` (`isSingleLineChar` for one-line fields). Rendering stays in the component: read `caretVisible(now_ms)` and `select_all`, and call `touch(now_ms)` when the field gains focus. Components must also report `wantsFrame` while a field is visible, or the caret will not blink under idle throttling.
- Text that can contain user or document content must be rendered through `src/ui/text_render.zig` (`makeTextTexture` with a `LineFonts` that carries `fonts.emoji`, or the `makeTextTextureEmoji` wrappers in `search_utils`/`diff_overlay`). Apple Color Emoji is a non-scalable bitmap font with a single 160 px strike, so rendering a string with the emoji fallback attached returns a ~160 px tall surface and one emoji dwarfs the line. Emoji are scaled by the ascent ratio, not to the line height: the surface SDL_ttf returns is the emoji font's full line box (160x210, glyph over empty descent padding), so fitting that box to the line height leaves the glyph sitting above the text baseline. Static app labels can keep the plain path.
- Single-line fields must bound their text: draw it with `text_render.drawClippedTail`, which tail-aligns an overflowing line so the caret stays visible and fades the leading edge into the field's fill. Never render a text texture at its natural width inside a fixed-width box.
- Overlays built on `ExpandingOverlay` must gate keyboard input and toggles on `state.isOpenOrOpening()`, never on `state == .Open`: the expand animation lasts ~200 ms, and keys typed during it otherwise fall through to the focused terminal.
- Static text badges (the collapsed `⌘O`/`⌘T`/`⌘?` overlay hints) must use `src/ui/components/glyph_badge.zig`. Never create-render-destroy an SDL texture within a single frame: destroying a texture that was queued for rendering forces SDL's Metal backend to flush the command queue and block on drawable acquisition (up to ~1 s under load). Cache textures and invalidate on font/theme changes.
- Cursor rendering: set the cursor's background color during the per-cell background pass and render the glyph on top; avoid drawing a separate cursor rectangle after text rendering, which hides the underlying glyph.
- ghostty-vt defaults: `Terminal.Options.max_scrollback_bytes` is 10_000 bytes and `0` disables scrollback entirely; set it explicitly when you expect deeper history. Ghostty's app sets 10 MB via `scrollback-limit` in Config.zig; upstream currently doesn't support unlimited scrollback. Use bytes, not lines, when sizing scrollback.

## Architecture Invariants (agent instructions)
- `io: std.Io` is threaded explicitly, as a struct field immediately after `allocator` or a parameter immediately after `allocator`. Never store it in a module-level variable. Structs whose threads outlive the spawner must store their own copy.
- `src/env.zig` is the only sanctioned module-level accessor in the codebase, because `std.Io` exposes no environment surface and the process environment is global and immutable. Do not add others.
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
- When copying persisted maps (e.g., `[terminals]`), duplicate both key and value slices; borrowing the parser's backing memory causes use-after-free crashes.
- Terminal cwd persistence is currently macOS-only; other platforms skip saving/restoring terminals to avoid stale directories until cross-platform cwd tracking is implemented.
- xev process watchers keep a pointer to the provided userdata; if you reuse a shared struct for multiple spawns, a late callback can read updated fields and wrongly mark a new session dead. Allocate a per-watcher context, free it on teardown or after the callback, and bump a generation counter on spawn/despawn to ignore stale events.
- Restart buttons should only render when a session is both `spawned` and `dead`; broader checks can surface controls for never-spawned slots.

## Claude Socket Hook
- The app creates `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock` and sets `ARCHITECT_SESSION_ID`/`ARCHITECT_NOTIFY_SOCK` for each shell.
- Send a single JSON line to signal UI states: `{"session":N,"state":"start"|"awaiting_approval"|"done"}`. The helper `scripts/architect_notify.py` is available if needed.
- Story notifications use the same socket: `{"session":N,"type":"story","path":"/absolute/path/to/story.md"}`. The `architect story <file>` subcommand sends this automatically.

## Done? Share
- Provide a concise summary of edits, test/build outcomes, and documentation updates.
- Suggest logical next steps only when they add value.
