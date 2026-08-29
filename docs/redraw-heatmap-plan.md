# Redraw Heatmap Overlay — Junior Dev Task Plan

This document is the implementation plan for GitHub issue
[#282 — Add a redraw heatmap overlay for repaint debugging](https://github.com/forketyfork/architect/issues/282).
Read it end-to-end before touching code. It links every step to a specific
file and (where it helps) a specific line, and points you at the existing
patterns in the codebase to copy.

If a section says "read this first" or "do this before X" — please do it
in that order. Architect's UI overlay system has strict layering rules
(see [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)), and it is much faster to
follow the conventions than to invent your own and refactor later.

---

## 1. What you are building

When the developer turns on a debug toggle (config flag + `⌘⇧H` keyboard
shortcut), Architect should draw a translucent colored rectangle on top
of every terminal tile whose **content was rerendered this frame**.
Each rectangle fades out smoothly over a short window (~500 ms) so the
developer can watch repaint activity at a glance:

- A session that streams output continuously stays "hot" (bright).
- A session that's idle goes back to invisible (no overlay).
- Switching grid/full view or scrolling produces a visible flash.

The overlay is **developer-only**. It must be off by default, must have
no measurable overhead when off, and must not change the visible output
in any user-visible way when off.

This task lives entirely inside Architect's existing layered architecture
(see [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)). You will not introduce
new architectural concepts.

---

## 2. Prerequisites — read these in this order

These are short. Do not skip them — most of the design decisions you
will make are already answered by these documents.

1. [`README.md`](../README.md) — only the "Features" section, so you
   understand the overall product.
2. [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — read top to bottom once.
   In particular, you must understand:
   - **ADR-002** (UI components + vtable dispatch) — your overlay is a
     `UiComponent`.
   - **ADR-003** (UiAction queue) — your toggle keyboard shortcut emits
     a `UiAction`, the runtime drains it.
   - **ADR-004** (epoch-based render cache) — this is the **signal**
     your overlay listens to. A session is "rerendered" when its
     `render_epoch` advances and the renderer actually repaints it.
   - **ADR-012** (`FirstFrameGuard`) — when the overlay toggles
     visible, you must mark a transition so the idle frame loop wakes
     up.
3. [`CLAUDE.md`](../CLAUDE.md) — sections "Coding Conventions",
   "Zig Language Gotchas", and "Architecture Invariants". These are
   enforced by the maintainer at review time.
4. [`docs/configuration.md`](configuration.md) — the `[metrics]` and
   `[ui]` sections, so you can model the new config option on them.

You should also skim **`src/ui/components/metrics_overlay.zig`**
([file](../src/ui/components/metrics_overlay.zig)) end to end. The
metrics overlay is the closest analog to what you are building: it is
toggled by a config flag + keyboard shortcut, lives in the bottom-right,
participates in the idle/wake protocol, and is a near-perfect template
for copy/paste/adapt. We will refer to it throughout this plan as
"the reference component".

---

## 3. How Architect renders (the part you care about)

You do not need to understand the whole renderer, but you do need to
understand which functions actually rerender a terminal's content,
because **those are the points where you record a "redraw event"**.

Open [`src/render/renderer.zig`](../src/render/renderer.zig). The
relevant call sites:

| Function | Line (approx.) | What it does | Is this a "redraw"? |
|---|---|---|---|
| `pub fn render(...)` | `renderer.zig:93` | Frame entry point — clears the screen, then dispatches to grid/full/pan rendering. | **Not** a redraw signal — it runs every frame; the work below is what differs. |
| `renderSession(...)` | `renderer.zig:309` | Non-cached path, renders a session directly to the screen. | **Yes** — actual cells are being drawn. |
| `renderSessionContent(...)` | `renderer.zig:333` | The actual cell-by-cell content draw (glyph shaping, cursor, backgrounds). | **Yes** — this is the work we want to visualize. |
| `renderSessionCached(...)` | `renderer.zig:1017` | Decides whether to use the cached texture or repaint via `refreshSessionCacheTexture`. | Reuses cache when possible. |
| `refreshSessionCacheTexture(...)` | `renderer.zig:967` | Renders cell content into the cached texture target. | **Yes** — this is the canonical "the cache was rebuilt" event. |
| `renderHeldSessionTexture(...)` | `renderer.zig:927` | Short-circuits during output holds / resize settle — presents the old texture as-is. | **No** — content is *not* rerendered. |
| `renderCachedTexture(...)` | `renderer.zig:1007` | Just blits an existing texture. | **No** — pure presentation, no draw. |

The epoch model (ADR-004) makes the rule simple:

> A session was rerendered this frame iff `refreshSessionCacheTexture`
> ran for it, or `renderSessionContent` ran outside the cache path
> (overlay fallback / pan animation).

The cleanest place to record the event is **at the top of
`refreshSessionCacheTexture` and inside the non-cached fallback in
`renderSessionCached` / `renderSession`**. You add a single call:

```zig
debug_redraw.recordSession(session.id, rect, current_time_ms);
```

That helper does nothing unless the overlay is enabled, so it is safe
to leave in the hot path permanently.

---

## 4. Design

### 4.1 Data flow

```
renderer.zig            debug_redraw.zig            redraw_heatmap_overlay.zig
+--------------+   record   +--------------+   read   +---------------------------+
| refresh      |----------> | RedrawLog    | <------- | render() draws fade rects |
| Session      |            | (ring buf)   |          | over each recent region   |
| Cache        |            +------+-------+          +---------------------------+
+--------------+                   ^
                                   | toggle on/off
                                   |
                              app/runtime.zig (config + UiAction drain)
```

### 4.2 New / changed files

- **NEW** `src/render/debug_redraw.zig` — the shared data model:
  a small struct that stores recent redraw rectangles + timestamps and
  exposes `record()`, `snapshot()`, and `clear()`. Compile-time-cheap
  no-op when disabled. Modeled on `src/metrics.zig`
  ([file](../src/metrics.zig)) — same pattern of an optional
  `pub var global: ?*RedrawLog = null;` plus inline pass-throughs.
- **NEW** `src/ui/components/redraw_heatmap_overlay.zig` — the UI
  component that reads the log and draws fading rectangles. Modeled on
  `src/ui/components/metrics_overlay.zig`.
- **Modified** `src/render/renderer.zig` — single import + 2–3
  `debug_redraw.record(...)` calls.
- **Modified** `src/ui/types.zig` — add `ToggleRedrawHeatmap: void`
  variant to `UiAction` (around `ui/types.zig:56`).
- **Modified** `src/ui/mod.zig` — re-export the new component
  (around `ui/mod.zig:23`).
- **Modified** `src/ui/components/global_shortcuts.zig` — add
  `⌘⇧H` shortcut emitting `ToggleRedrawHeatmap`.
- **Modified** `src/ui/components/help_overlay.zig` — add the
  shortcut to the `shortcuts[]` table near `help_overlay.zig:13`.
- **Modified** `src/config.zig` — add `DebugConfig` struct and wire it
  into `Config` (next to `MetricsConfig` at `config.zig:229`).
- **Modified** `src/app/runtime.zig` — instantiate the overlay,
  register it, handle the `ToggleRedrawHeatmap` action, and gate the
  whole subsystem on `config.debug.redraw_heatmap`.
- **Modified** `docs/configuration.md` — document the new flag.
- **Modified** `docs/ARCHITECTURE.md` — short paragraph + module table
  row for the new debug overlay.

That's it. No new dependencies (issue #282 explicitly says "New
Dependencies: None").

### 4.3 What the log stores

Keep the model tiny. A fixed-size ring buffer is enough; we do not
need allocation in the hot path.

```zig
// src/render/debug_redraw.zig
pub const RedrawEvent = struct {
    session_id: usize,
    rect: Rect,            // screen-space rectangle, in render coords
    timestamp_ms: i64,     // host.now_ms when recorded
    kind: Kind,            // .full_redraw or .cache_refresh
};

pub const Kind = enum(u8) { full_redraw, cache_refresh };

pub const RedrawLog = struct {
    events: [max_events]RedrawEvent = undefined,
    head: usize = 0,           // index of next write (mod max_events)
    count: usize = 0,          // number of valid entries (<= max_events)

    pub const max_events: usize = 256;
    pub const fade_duration_ms: i64 = 500;

    pub fn record(self: *RedrawLog, ev: RedrawEvent) void { ... }
    pub fn snapshot(self: *const RedrawLog) []const RedrawEvent { ... }
    pub fn clear(self: *RedrawLog) void { ... }
};

pub var global: ?*RedrawLog = null;

pub inline fn record(session_id: usize, rect: Rect, ts_ms: i64, kind: Kind) void {
    if (global) |log| log.record(.{ ... });
}
```

The `pub inline fn record(...)` pattern is exactly how
`src/metrics.zig:62-69` exposes a zero-cost no-op when the feature is
off. Use the same idiom so the call sites in `renderer.zig` compile
down to nothing when disabled.

**Why a ring buffer, not a dynamic list?** No allocations on the hot
path; bounded memory; old events naturally expire as new ones overwrite
them. 256 events is plenty for a 12×12 grid at 60 FPS with a 500 ms
fade window (max 12×12 = 144 active rectangles).

### 4.4 Rendering the fades

In the overlay component's `render`:

1. If not visible, return.
2. Walk `RedrawLog.snapshot()`.
3. For each event, compute `age_ms = host.now_ms - ev.timestamp_ms`.
   If `age_ms >= fade_duration_ms`, skip it.
4. Compute `alpha_f = 1.0 - age_ms / fade_duration_ms` and apply an
   easing curve. Use `easing.easeOutCubic` from
   [`src/anim/easing.zig`](../src/anim/easing.zig:11) — the same
   easing other fading UI elements use.
5. Draw a filled rectangle at `ev.rect` with the chosen color and the
   eased alpha. Use SDL's blend mode:
   ```zig
   _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
   _ = c.SDL_SetRenderDrawColor(renderer, r, g, b, alpha);
   _ = c.SDL_RenderFillRect(renderer, &rect_f);
   ```
   See `metrics_overlay.zig:132-135` for the exact pattern.
6. Optionally draw a 1-pixel border at the same color but full alpha,
   so very brief events are still visible.

**Color choice:** issue #282 says we should leave room to distinguish
"cache refresh" from "full content redraw". Use two colors:
- `Kind.cache_refresh`: warm yellow `(255, 200, 60)` — common case.
- `Kind.full_redraw`: red `(255, 80, 80)` — for the rarer
  uncached/animation path.

Hard-code these for now. We are not exposing them as config; this is
a debug tool, the maintainer will tell you if they want them themed.

### 4.5 Toggle and visibility lifecycle

This is where you get to copy `metrics_overlay.zig` almost verbatim.
Open it side-by-side and use it as a template. The contract is:

- `init(allocator)` creates the component, with `visible = false`.
- `toggle()` flips `visible` and calls
  `self.first_frame.markTransition()`
  ([`first_frame_guard.zig`](../src/ui/first_frame_guard.zig)) so the
  idle frame loop wakes immediately and the next render happens this
  frame, not 250 ms later.
- `wantsFrame()` returns
  `self.first_frame.wantsFrame() or (self.visible and has_live_events)`
  so the frame loop keeps rendering while events are still fading.
  Note this is **richer** than the metrics overlay — you need to keep
  rendering even when no terminal output is happening, as long as some
  redraw rectangles are still mid-fade. See
  `metrics_overlay.zig:84-87` for the simpler version.
- `handleEvent` does **nothing**. The toggle keyboard shortcut lives in
  `global_shortcuts.zig` (see §5.3). The metrics overlay handles its
  own shortcut, but for ours the global shortcuts component is the
  better home, because there is no need for the overlay to be visible
  to receive the toggle key (you would not be able to turn it back
  off otherwise).
- `render` does the loop described in §4.4.
- `deinit` destroys the component. No textures to free — we draw with
  immediate `SDL_RenderFillRect` calls, not pre-rendered textures.

The component's `z_index` should be **higher than the metrics
overlay's 950** so it renders on top of metrics too — pick `960`.

---

## 5. Step-by-step implementation order

Implement and verify these steps **in this order**. Run
`zig build` after each step. Run `zig build test` and `just lint`
before each commit.

### 5.1 Step 1 — Add the data model

Create `src/render/debug_redraw.zig`. Implement `RedrawLog`,
`RedrawEvent`, the `record()` ring-buffer logic, the `snapshot()`
accessor, and the inline pass-through helpers.

Add unit tests in the same file (Zig convention). At minimum:

- `test "RedrawLog.record adds events up to max_events"`
- `test "RedrawLog.record wraps around past max_events"`
- `test "RedrawLog.snapshot returns events in insertion order"`
- `test "record() is a no-op when global is null"` (same shape as
  `metrics.zig:90-95` "global metrics null check").

Reference: [`src/metrics.zig`](../src/metrics.zig) is the closest
existing module to this one — same pattern, same test style.

After this step `zig build test` should still pass and the new tests
should run.

### 5.2 Step 2 — Wire instrumentation into the renderer

In [`src/render/renderer.zig`](../src/render/renderer.zig):

1. Add `const debug_redraw = @import("debug_redraw.zig");` near the
   other imports at the top of the file.
2. At the top of `refreshSessionCacheTexture` (line `~967`), after
   the function-entry log line at `renderer.zig:986`, add:
   ```zig
   debug_redraw.record(session.id, rect, current_time_ms, .cache_refresh);
   ```
3. In `renderSessionCached`'s non-cached fallback (around
   `renderer.zig:1068`), where we call `renderSession(...)` or
   `renderSessionContent(...)`, record a `.full_redraw` event.
4. In `renderSession` itself (line `~309`), if it is ever called from
   a path that does **not** go through `renderSessionCached` (the pan
   animation paths at `renderer.zig:179` and `renderer.zig:199` do
   this), also record a `.full_redraw`. To keep this simple, put the
   `debug_redraw.record(...)` call at the top of `renderSession`
   itself and **remove** the duplicate call from the non-cached
   fallback. That way every actual redraw path is covered with exactly
   one call.

Verify `zig build` still passes. Nothing visible will change yet — the
data is being recorded into a null `global`.

### 5.3 Step 3 — Add the config flag

In [`src/config.zig`](../src/config.zig):

1. Just after `MetricsConfig` (around `config.zig:229`), add:
   ```zig
   pub const DebugConfig = struct {
       redraw_heatmap: bool = false,
   };
   ```
2. Add the field to `Config` (around `config.zig:783`):
   ```zig
   debug: DebugConfig = .{},
   ```
3. Add the commented-out section to the template inside
   `createDefaultConfigFile` (around `config.zig:860`). Mirror the
   `[metrics]` block:
   ```zig
   \\# Debug overlays (developer-only)
   \\# [debug]
   \\# redraw_heatmap = false  # Toggle with ⌘⇧H when enabled
   \\
   ```
4. Add a unit test next to the existing `show_hotkey_feedback = false`
   test (around `config.zig:1026-1052`) that loads
   `[debug]\nredraw_heatmap = true\n` and asserts
   `config.debug.redraw_heatmap == true`.

### 5.4 Step 4 — Add the UiAction variant

In [`src/ui/types.zig`](../src/ui/types.zig:56), add a new variant to
`UiAction`:

```zig
ToggleRedrawHeatmap: void,
```

Just add it; you'll wire the producer and consumer in the next two
steps. After this step `zig build` will compile — `UiAction` is an
untagged union of payloads, so an unused variant is harmless.

### 5.5 Step 5 — Add the keyboard shortcut

In
[`src/ui/components/global_shortcuts.zig`](../src/ui/components/global_shortcuts.zig:38),
inside `handleEvent`, after the existing `SDLK_COMMA` block, add:

```zig
const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;
if (key == c.SDLK_H and has_gui and has_shift and !has_blocking_mod) {
    actions.append(.ToggleRedrawHeatmap) catch |err| {
        log.warn("failed to queue toggle redraw heatmap action: {}", .{err});
    };
    return true;
}
```

Note: the existing pattern uses `!has_blocking_mod` to exclude Ctrl/Alt
chords. We match that. `⌘⇧H` is unused today. Verify by searching:
`rg -n 'SDLK_H\b' src/`.

Then update the help overlay shortcut list in
[`src/ui/components/help_overlay.zig`](../src/ui/components/help_overlay.zig:13).
Add (in a sensible position near `⌘D`, since both are dev-ish):

```zig
.{ .key = "⌘⇧H", .desc = "Toggle redraw heatmap (debug)" },
```

### 5.6 Step 6 — Implement the overlay component

Create `src/ui/components/redraw_heatmap_overlay.zig`.

Start from a copy of `metrics_overlay.zig` and:

1. Replace all `MetricsOverlayComponent` identifiers with
   `RedrawHeatmapOverlayComponent`.
2. Replace the texture / `ensureTexture` machinery with a direct
   render loop (we draw filled rectangles, not text). See §4.4.
3. Delete `update`, `dirty`, `font_generation`, `last_sample_ms`,
   `cached_elapsed_ms`, `texture`, `tex_w`, `tex_h`. They are not
   needed.
4. Replace the `handleEvent` body with a `return false;` — the
   shortcut lives in `global_shortcuts`.
5. Implement `wantsFrame` as described in §4.5: keep returning `true`
   while any event is still within its fade window.
6. Set `z_index = 960` in `asComponent`.
7. Export it from `src/ui/mod.zig` next to the existing
   `metrics_overlay` line at `ui/mod.zig:23`.

Add a small test in the same file:

- `test "wantsFrame returns false when invisible and no live events"`
- `test "wantsFrame returns true when invisible but events are still fading"`
- `test "wantsFrame returns true while first-frame guard is hot"`

These can be plain table-driven tests against the visibility helper
function — you do not need to spin up SDL. Pull the alpha/visibility
math out into a small free function (e.g.
`pub fn liveEventsCount(snapshot, now_ms, fade_duration_ms) usize`)
so it is unit-testable without a renderer.

### 5.7 Step 7 — Wire it into the runtime

In [`src/app/runtime.zig`](../src/app/runtime.zig):

1. Around the existing metrics setup at `runtime.zig:1344-1346`, add
   the equivalent for the redraw log:
   ```zig
   var redraw_log_storage = debug_redraw.RedrawLog{};
   const redraw_log_ptr: ?*debug_redraw.RedrawLog =
       if (config.debug.redraw_heatmap) &redraw_log_storage else null;
   debug_redraw.global = redraw_log_ptr;
   ```
   (You'll need to add `const debug_redraw = @import("../render/debug_redraw.zig");`
   to the imports at the top of the file.)
2. Where the metrics overlay is registered at `runtime.zig:1545-1546`,
   register the new overlay just after it:
   ```zig
   const redraw_heatmap_component = try ui_mod.redraw_heatmap_overlay.RedrawHeatmapOverlayComponent.init(allocator);
   try ui.register(redraw_heatmap_component.asComponent());
   ```
3. In the `UiAction` drain loop (where `ToggleMetrics` is handled at
   `runtime.zig:2843-2850`), add a sibling branch:
   ```zig
   .ToggleRedrawHeatmap => {
       if (config.debug.redraw_heatmap) {
           redraw_heatmap_component.toggle();
           if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧H", now);
       } else {
           ui.showToast("Redraw heatmap disabled in config", now);
       }
   },
   ```
4. At shutdown, set `debug_redraw.global = null;` symmetrically with
   the metrics teardown. Look for where `metrics_mod.global` is
   cleared, if anywhere; if it is not explicitly cleared today, just
   ensure `debug_redraw.global` is not used after the storage goes out
   of scope. Since `redraw_log_storage` is a stack local declared
   above the main loop, this is already safe — but null the global out
   right before the function returns to be explicit:
   ```zig
   defer debug_redraw.global = null;
   ```
   Place this `defer` right after the assignment in step 1.

After this step `zig build && zig build run` should let you flip the
config flag, restart the app, and toggle the overlay with `⌘⇧H`.

### 5.8 Step 8 — Update documentation

This is **not optional** — see CLAUDE.md "Documentation Hygiene"
section.

1. [`docs/configuration.md`](configuration.md): add a new section
   after the "Metrics Configuration" section, with the same shape:
   ````markdown
   ### Debug Configuration

   ```toml
   [debug]
   redraw_heatmap = false  # default: false
   ```

   When enabled, press `⌘⇧H` to toggle a translucent heatmap overlay
   that highlights terminal tiles whose content was rerendered this
   frame. Each rectangle fades over ~500 ms. Yellow indicates a
   cached-texture refresh; red indicates a full uncached repaint.

   Intended for development and performance debugging. There is no
   measurable cost when disabled.
   ````
2. [`docs/ARCHITECTURE.md`](ARCHITECTURE.md):
   - Add a row to the "Module Boundary Table" for
     `render/debug_redraw.zig`.
   - Add a row for `ui/components/redraw_heatmap_overlay.zig`.
   - In the "Where to Put New Code" table, no change is needed —
     this fits the existing "Add a new UI element (overlay)" row.
3. [`CLAUDE.md`](../CLAUDE.md): no change. This is a normal overlay
   that follows the existing invariants; no new gotcha to record.
4. [`README.md`](../README.md): no change. This is a developer tool,
   not a user feature.

---

## 6. Testing & verification

### 6.1 Automated

```bash
zig build           # must pass
zig build test      # must pass; your new tests should appear
just lint           # must pass (run from repo root inside `nix develop`)
zig fmt --check src/  # must pass; run `zig fmt src/` if it fails
```

Unit-test coverage to hit:

- `RedrawLog.record` ring-buffer behavior (insertion, wrap, snapshot
  order) — `src/render/debug_redraw.zig`.
- `record()` no-op when `global` is null — same file.
- Visibility/`wantsFrame` math — `src/ui/components/redraw_heatmap_overlay.zig`.
- Config parsing for the new `[debug] redraw_heatmap` flag —
  `src/config.zig`.

### 6.2 Manual (this is required — see CLAUDE.md "Observability")

Because rendering is involved, you cannot fully verify this from CI.
Run the app yourself and confirm each item below. Capture a short
screen recording or a couple of screenshots for the PR description.

1. **Off by default.** With no config changes, launch the app. Press
   `⌘⇧H`. You should see a toast ("Redraw heatmap disabled in
   config"). No overlay should appear. No visual change anywhere.
2. **Enable the flag.** Edit `~/.config/architect/config.toml`:
   ```toml
   [debug]
   redraw_heatmap = true
   ```
   Restart Architect.
3. **Idle.** With the flag enabled but `⌘⇧H` not pressed: no
   visual change.
4. **Toggle on.** Press `⌘⇧H`. The hotkey indicator should show
   `⌘⇧H` (because `show_hotkey_feedback = true`).
5. **Streaming output.** Run `yes | head -5000` in a terminal.
   The corresponding tile should glow yellow and pulse as the cache
   is refreshed each frame. Stop the command. The glow should fade
   within 500 ms.
6. **Grid navigation.** With multiple terminals, press `⌘→`. The
   destination tile's wave animation should produce visible red
   "full redraw" rectangles (the pan/wave animation uses the
   non-cached path).
7. **Idle behavior.** Leave the overlay on with everything quiet.
   The frame loop should go idle (no CPU spike), which proves
   `wantsFrame` is correctly returning `false` when there are no
   live events.
8. **Toggle off.** Press `⌘⇧H` again. The overlay disappears
   immediately (within one frame). No leftover ghost rectangles.
9. **Quit + relaunch.** The config flag persists; the overlay
   visibility does not (it always starts hidden after launch — this
   is intentional, do not persist it).
10. **Performance.** With the flag **disabled**, run
    `yes | head -100000` in one tile. CPU/FPS should match baseline.
    Then enable the flag (no toggle) and repeat. Still no measurable
    overhead — the `inline` no-op guarantees this; this manual check
    just confirms it.

### 6.3 Things that should NOT happen

If you see any of the following, something is wrong:

- Rectangles draw under the cwd bar, hotkey indicator, or any other
  UI element with `z_index <= 950`. Your `z_index` is too low.
- Rectangles draw on top of the metrics overlay text but obscure it.
  Reduce alpha or accept the trade — note in the PR.
- App stays at 60 FPS forever after toggling on with no streaming
  output. `wantsFrame` is returning `true` when it should not.
- Toggling the overlay while a session is held (post-resize / output
  hold) produces missing or stale rectangles. Confirm via the table
  in §3 that you are recording events at the right call sites.
- New `try ... catch unreachable` or `catch {}` patterns anywhere.
  See CLAUDE.md "Error handling".

---

## 7. Edge cases you must handle

1. **Session despawn / index reuse.** `session_id` in a redraw event
   may refer to a session that was closed and respawned by the time
   it is drawn. The rectangle is screen-space, not session-space, so
   this is fine — but make sure you do not dereference any
   `SessionState*` from the overlay's render path. Events should
   carry **only** the screen rect and the kind, not a session
   pointer.
2. **Window resize.** If the window shrinks between recording and
   drawing, an old rectangle could extend past the new window. Clamp
   to `host.window_w` / `host.window_h` in the overlay before
   drawing.
3. **Grid layout change.** Same as above — if a tile moved, the old
   rectangle is stale. That is fine: it will fade out in 500 ms.
   Do not try to "fix it up". The point is to show what was actually
   rendered.
4. **High DPI.** All `Rect` values in the renderer are already in
   render coordinates (post-DPI scale). Do not re-scale.
5. **Toggle while events are mid-fade.** When the overlay is hidden,
   keep recording events in the log — they will simply not be drawn.
   When toggled back on, in-flight events fade out cleanly. This is
   automatic if you implement step 5 correctly.

---

## 8. Definition of done

All boxes must be checked before opening the PR:

- [ ] All files in §4.2 created or modified.
- [ ] `zig build` passes.
- [ ] `zig build test` passes, including new tests for `RedrawLog`,
      the `wantsFrame` math, and config parsing.
- [ ] `just lint` and `zig fmt --check src/` pass.
- [ ] Manual checks 1–10 in §6.2 pass; you captured at least one
      screenshot/recording showing the heatmap rectangles in action.
- [ ] [`docs/configuration.md`](configuration.md) and
      [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) updated.
- [ ] No new dependencies in `build.zig.zon`.
- [ ] Commit messages follow conventional commit format
      (`feat: ...`, `docs: ...` — see existing `git log` for the style).
- [ ] PR description links back to issue #282 with `Closes #282`.
- [ ] PR description includes the screenshot/recording.

---

## 9. Pointers when you get stuck

- "How does `xxx_overlay.zig` register a shortcut?" — See
  `metrics_overlay.zig:62-81`. Note: for *your* overlay the shortcut
  lives in `global_shortcuts.zig` instead; the metrics overlay does
  it in-component.
- "How does the frame loop decide to wake up?" — See
  `app/runtime.zig` around line `1559` ("Main loop:" comment) and
  trace `FrameWaitDecision`. The short answer: any component's
  `wantsFrame() == true` keeps it active; `FirstFrameGuard.wantsFrame`
  ([`src/ui/first_frame_guard.zig`](../src/ui/first_frame_guard.zig))
  expires after one render via `markDrawn()`.
- "Why is my overlay flickering on first show?" — You forgot
  `markTransition()` in `toggle()`. See ADR-012 in
  [`docs/ARCHITECTURE.md`](ARCHITECTURE.md).
- "Why does `@min` give me weird types?" — Read the "Type Inference
  with Builtin Functions" section of [`CLAUDE.md`](../CLAUDE.md).
  Use `: usize` annotations.
- SDL3 docs: https://wiki.libsdl.org/SDL3/ — useful entries for this
  task: `SDL_SetRenderDrawBlendMode`, `SDL_SetRenderDrawColor`,
  `SDL_RenderFillRect`, `SDL_FRect`. All already used by
  `metrics_overlay.zig`.
- Zig 0.15 docs: https://ziglang.org/documentation/0.15.0/ —
  especially `std.ArrayList` semantics (init/initCapacity), which
  CLAUDE.md flags as a known gotcha.

---

## 10. Out of scope (do not do these)

Issue #282 lists these explicitly as out of scope. Do not be tempted:

- Exact GPU-driver-level damage reporting.
- Shipping the overlay as always-on user-facing UI.
- Refactoring the renderer's caching scheme. If you find yourself
  considering this, stop and ask in the PR before continuing.
- Adding a config option for the colors or fade duration. Hard-coded
  is fine for v1.
- Persisting the overlay's visibility across launches. Always start
  hidden.
- Exposing the recorded events via the `architect-mcp` interface or
  the local control socket. Strictly an in-process visualization.

Keep the change tight. The whole task should land in well under
~600 LOC of new code (closer to ~300 LOC + tests is realistic),
plus the doc updates.
