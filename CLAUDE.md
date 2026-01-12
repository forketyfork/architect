# CLAUDE.md

Guidance for any code agent working on the Architect repo. Keep this file instruction-oriented—refer to `README.md` for product details.

## Quick Workflow
1. Read the task and skim `README.md` for expected behavior; avoid duplicating that content here.
2. Ghostty is fetched via Zig package manager; run `just setup` only if you want to pre-cache the tarball before building.
3. Work inside the dev shell: `nix develop` (or `direnv allow`).
4. Prefer repo-friendly tools: `rg`/`fd` for search, `fastmod` or `sg` for refactors, `tree` for structure, `date` for timestamps, `gh` for PR/comment context.
5. For Zig changes, use the `zig-best-practices` skill; if it is not installed, install it via the skill installer before editing.

## Coding Conventions
- Favor self-documenting code; keep comments minimal and meaningful.
- Default to ASCII unless the file already uses non-ASCII.
- Always handle errors explicitly: propagate, recover, or log; do not swallow errors with bare `catch {}` / `catch unreachable` unless proven impossible.
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
**Problem:** Zig's builtin functions like `@min`, `@max`, and `@clamp` infer result types from their operands. When using comptime constants, this can produce unexpectedly narrow types that cause silent integer wrapping.

**Example Bug:**
```zig
// WRONG: @min infers u2 (2-bit type) from the constant 2, wrapping at 4
const grid_col = @min(@as(usize, col_index), GRID_COLS - 1);  // if GRID_COLS=3
const result = row * GRID_COLS + grid_col;  // 1*3+1 = 4, wraps to 0 in u2!
```

**Solution:** Explicitly cast comptime constants to the desired type:
```zig
// CORRECT: Both operands are usize, result is usize
const grid_col: usize = @min(@as(usize, col_index), @as(usize, GRID_COLS - 1));
const result = row * GRID_COLS + grid_col;  // Works correctly
```

**When to be careful:**
- Using `@min`, `@max`, `@clamp` with comptime integer literals or constants
- Arithmetic operations where the result might exceed the inferred type's range
- Index calculations, especially for grids or arrays (values 0-3 fit in u2, but 4+ wrap)

**General rule:** When working with indices, sizes, or any value that might grow, explicitly annotate or cast to `usize` or an appropriate sized type.

### Naming collisions in large render functions
- When hoisting shared locals (e.g., `cursor`) to wider scopes inside long functions, avoid re-declaring them later with the same name. Zig treats this as shadowing and fails compilation. Prefer a single binding per logical value or choose distinct names for nested scopes to prevent “local constant shadows” errors.

## Build and Test (required after every task)
- Run `zig build` and `zig build test` (or `just ci` when appropriate) once the task is complete.
- Report the results in your summary; if you must skip tests, state the reason explicitly.

## Documentation Hygiene (REQUIRED)
- **ALWAYS** update documentation when making changes. This is not optional.
- Update `README.md` for any user-facing changes: new features, configuration options, keyboard shortcuts, or behavior changes.
- Update `docs/architecture.md` when adding new components, modules, or changing the system structure.
- Keep this `CLAUDE.md` aligned when workflows or automation expectations change.
- Documentation updates should be part of the same PR as the code changes.

## Repo Notes
- Architect is a Zig app using the ghostty-vt dependency fetched via the Zig package manager; avoid reintroducing a checked-out `ghostty/` path assumption.
- User config lives in `~/.config/architect/config.toml`. Maintain compatibility or add migrations when changing config shape.
- `just` commands mirror zig builds (`just build`, `just run`, `just test`, `just ci`); use them when adjusting CI scripts or docs.
- Shared UI/render utilities live in `src/geom.zig` (Rect + point containment), `src/anim/easing.zig` (easing), and `src/gfx/primitives.zig` (rounded/thick borders); reuse them instead of duplicating helpers.
- The UI overlay pipeline is centralized in `src/ui/`—`UiRoot` receives events before `main`’s switch, runs per-frame `update`, drains `UiAction`s, and renders after the scene; register new components there rather than adding more UI logic to `main.zig`.
- Architecture overview lives in `docs/architecture.md`—consult it before structural changes.
- Reusable marquee text rendering lives in `src/ui/components/marquee_label.zig`; use it instead of re-implementing scroll logic.
- Cursor rendering: set the cursor’s background color during the per-cell background pass and render the glyph on top; avoid drawing a separate cursor rectangle after text rendering, which hides the underlying glyph.

## Architecture Invariants (agent instructions)
- Route UI input/rendering through `UiRoot` only; do not add new UI event branches or rendering in `main.zig` or `renderer.zig`.
- Keep scene rendering (`renderer.zig`) focused on terminals/scene overlays; UI components belong in `src/ui/components/` and render after `renderer.render(...)`.
- Do not store UI state or UI textures in session structs or `app_state.zig`; UI state must live inside UI components or UI-managed assets.
- Add new UI features by registering components with `UiRoot`; never bypass `UiAction` for UI→app mutations.
- When a UI component moves into a new visible state (modals expanding, toasts appearing, gesture indicators starting), use `src/ui/first_frame_guard.zig`: call `markTransition()` when the state flips and `markDrawn()` at the end of the first render; have `wantsFrame` return `guard.wantsFrame()` so the main loop renders immediately even under idle throttling.

## Rendering & Unicode Notes
- Only read `cell.content.codepoint` when `content_tag == .codepoint`; palette-only or non-text cells should render as empty. Misreading other tags produces spurious replacement glyphs.
- Sanitize incoming codepoints before shaping: replace surrogates or values above `0x10_FFFF` with U+FFFD to prevent `utf8CodepointSequenceLength` errors from malformed TTY/OSC output.

## Known Pitfalls
- Session teardown can run twice on error paths (errdefer plus outer defer). Keep `SessionState.deinit` idempotent: destroy textures/fonts/watchers, then null pointers and reset flags; in `main.zig` only deinit sessions that were actually constructed.

## Claude Socket Hook
- The app creates `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock` and sets `ARCHITECT_SESSION_ID`/`ARCHITECT_NOTIFY_SOCK` for each shell.
- Send a single JSON line to signal UI states: `{"session":N,"state":"start"|"awaiting_approval"|"done"}`. The helper `architect_notify.py` is available if needed.

## Done? Share
- Provide a concise summary of edits, test/build outcomes, and documentation updates.
- Suggest logical next steps only when they add value.
