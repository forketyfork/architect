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
- Run `zig fmt src/` (or `zig fmt` on touched Zig files) before wrapping up changes.
- Avoid destructive git commands and do not revert user changes.

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

## Build and Test (required after every task)
- Run `zig build` and `zig build test` (or `just ci` when appropriate) once the task is complete.
- Report the results in your summary; if you must skip tests, state the reason explicitly.

## Documentation Hygiene
- Update `README.md` and any relevant docs to reflect behavior, configuration, build, or workflow changes.
- Keep this `CLAUDE.md` aligned when workflows or automation expectations change.

## Repo Notes
- Architect is a Zig app using the ghostty-vt dependency fetched via the Zig package manager; avoid reintroducing a checked-out `ghostty/` path assumption.
- User config lives in `~/.config/architect/config.json`. Maintain compatibility or add migrations when changing config shape.
- `just` commands mirror zig builds (`just build`, `just run`, `just test`, `just ci`); use them when adjusting CI scripts or docs.
- Shared UI/render utilities live in `src/geom.zig` (Rect + point containment), `src/anim/easing.zig` (easing), and `src/gfx/primitives.zig` (rounded/thick borders); reuse them instead of duplicating helpers.
- The UI overlay pipeline is centralized in `src/ui/`—`UiRoot` receives events before `main`’s switch, runs per-frame `update`, drains `UiAction`s, and renders after the scene; register new components there rather than adding more UI logic to `main.zig`.
- Architecture overview lives in `docs/architecture.md`—consult it before structural changes.
- Reusable marquee text rendering lives in `src/ui/components/marquee_label.zig`; use it instead of re-implementing scroll logic.

## Architecture Invariants (agent instructions)
- Route UI input/rendering through `UiRoot` only; do not add new UI event branches or rendering in `main.zig` or `renderer.zig`.
- Keep scene rendering (`renderer.zig`) focused on terminals/scene overlays; UI components belong in `src/ui/components/` and render after `renderer.render(...)`.
- Do not store UI state or UI textures in session structs or `app_state.zig`; UI state must live inside UI components or UI-managed assets.
- Add new UI features by registering components with `UiRoot`; never bypass `UiAction` for UI→app mutations.

## Claude Socket Hook
- The app creates `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock` and sets `ARCHITECT_SESSION_ID`/`ARCHITECT_NOTIFY_SOCK` for each shell.
- Send a single JSON line to signal UI states: `{"session":N,"state":"start"|"awaiting_approval"|"done"}`. The helper `architect_notify.py` is available if needed.

## Done? Share
- Provide a concise summary of edits, test/build outcomes, and documentation updates.
- Suggest logical next steps only when they add value.
