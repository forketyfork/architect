# Architect UI Framework Refactor Plan (Option A)

Goal: stop “UI hacked into main + renderer” from expanding into a hydra. Build a small, reusable UI layer with (1) a component registry, (2) time-based animations per component, (3) event handling with capture/consume semantics, and (4) rendering as a separate overlay pass after the scene render. Then port the current UI bits (“Restart” button, “?” help overlay, toast, ESC hold indicator) into real components.

Option A constraint: keep `src/render/renderer.zig` focused on rendering the *scene* (the terminals + their borders/overlays that are truly part of the scene). UI is rendered after `renderer.render(...)` and handles its own input.

---

## 0) Invariants + success criteria

Success criteria:

* No UI hit-testing in `src/main.zig` (mouse/key dispatch goes into UI root first).
* No UI state types living in `app_state.zig` (they move into `src/ui/...`).
* UI rendering is a single call from `main` after scene render: `ui.render(...)`.
* “Restart” and “?” are implemented as components (drawing + hit-testing + state).
* It’s easy to add a new component without touching `main.zig` event switch.

Non-goals (for now):

* A full retained-mode layout engine / flexbox.
* Backend-agnostic rendering (we’ll use SDL directly).
* Perfect decoupling from app state. We’ll keep a small “host snapshot” struct.

---

## 1) Create shared utility modules (avoid cycles) ✅

### 1.1 Geometry module

Add:

* `src/geom.zig`

Responsibilities:

* Own `Rect` and point containment helpers so UI and renderer don’t depend on each other for trivial math.

Minimal API:

```zig
pub const Rect = struct { x: c_int, y: c_int, w: c_int, h: c_int };

pub fn containsPoint(r: Rect, x: c_int, y: c_int) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}
```

Then:

* In `src/app/app_state.zig`, replace the `Rect` definition with `pub const Rect = @import("../geom.zig").Rect;` (or keep it and alias `geom.Rect`—either way, consolidate usage gradually).

### 1.2 Shared easing (animations used by UI + app)

Add:

* `src/anim/easing.zig`

```zig
pub fn easeInOutCubic(t: f32) f32 { ... } // move from AnimationState
```

Then:

* Update `AnimationState.easeInOutCubic` to call `anim.easing.easeInOutCubic` (or remove the method and call the shared function everywhere).

### 1.3 Shared drawing primitives (renderer + UI)

Add:

* `src/gfx/primitives.zig`

Move/copy from `renderer.zig`:

* `drawRoundedBorder`
* `drawThickBorder`
* any arc helper used by the ESC indicator (if one exists; if not, implement locally in UI for now).

Then:

* `src/render/renderer.zig` imports `gfx/primitives.zig`
* UI components import `gfx/primitives.zig`

---

## 2) Build the minimal UI framework ✅

Add folder:

* `src/ui/`

Add core files:

* `src/ui/types.zig` (shared types: `UiAction`, `UiContext`, host snapshot)
* `src/ui/component.zig` (vtable + wrapper)
* `src/ui/root.zig` (registry, dispatch, actions queue)
* `src/ui/mod.zig` (re-export public UI API)

### 2.1 Host snapshot (what UI can “see” each frame)

Create a compact read-only snapshot struct so UI doesn’t reach into everything:

```zig
pub const UiHost = struct {
    now_ms: i64,

    window_w: c_int,
    window_h: c_int,

    grid_cols: usize,
    grid_rows: usize,
    cell_w: c_int,
    cell_h: c_int,

    view_mode: ViewMode,        // from app_state
    focused_session: usize,

    sessions_dead: []const bool, // or []const SessionUiInfo
};
```

You can start with `[]const SessionUiInfo` if you need more than `dead` soon:

```zig
pub const SessionUiInfo = struct { dead: bool, spawned: bool };
```

### 2.2 UI actions (UI -> app)

Create:

```zig
pub const UiAction = union(enum) {
    RestartSession: usize,
    RequestCollapseFocused: void,
    // optional later: OpenHelp, CloseHelp, etc (help can also be purely internal)
};
```

### 2.3 Component interface

Create a vtable-based interface so any component can be registered:

```zig
pub const UiComponent = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    z_index: i32 = 0, // for layering

    pub const VTable = struct {
        handleEvent: ?*const fn (ptr: *anyopaque, host: *const UiHost, event: *const c.SDL_Event, out: *UiActionQueue) bool = null,
        update: ?*const fn (ptr: *anyopaque, host: *const UiHost, out: *UiActionQueue) void = null,
        render: ?*const fn (ptr: *anyopaque, host: *const UiHost, renderer: *c.SDL_Renderer, assets: *UiAssets) void = null,
        deinit: ?*const fn (ptr: *anyopaque, renderer: *c.SDL_Renderer) void = null,
    };
};
```

Important behavioral rules:

* Event dispatch is **topmost-first**: components sorted by `z_index` descending.
* Render is **bottommost-first**: ascending.
* A component returns `true` from `handleEvent` to consume the event (stop propagation).
* Components push `UiAction`s into a queue owned by `UiRoot`.

### 2.4 UiRoot

`UiRoot` owns:

* `components: ArrayList(UiComponent)`
* `actions: ArrayList(UiAction)` (or a small ring buffer)
* `assets: UiAssets` (cached fonts/textures)

API:

```zig
pub fn init(allocator: Allocator) UiRoot
pub fn deinit(self: *UiRoot, renderer: *c.SDL_Renderer) void

pub fn register(self: *UiRoot, c: UiComponent) !void

pub fn handleEvent(self: *UiRoot, host: *const UiHost, event: *const c.SDL_Event) bool
pub fn update(self: *UiRoot, host: *const UiHost) void
pub fn render(self: *UiRoot, host: *const UiHost, renderer: *c.SDL_Renderer) void

pub fn popAction(self: *UiRoot) ?UiAction
```

---

## 3) Integrate UI root into `main.zig` ✅

### 3.1 Instantiate and register components

In `main`, replace:

* `toast_notification`, `help_button`, `escape_indicator` locals

With:

* `var ui = ui_mod.UiRoot.init(allocator);`
* register components in init section:

  * `HelpOverlayComponent`
  * `ToastComponent`
  * `EscapeHoldComponent`
  * `RestartButtonsOverlayComponent`

### 3.2 Event loop: UI first, then app

In the SDL event loop:

1. Build `UiHost` snapshot (cheap; just fill fields).
2. Call `const consumed = ui.handleEvent(&host, &event);`
3. If `consumed`, skip the rest of the old event handling **for that event**.
4. Otherwise run existing app logic (terminal input, grid click-to-expand, scrolling, etc).

Then after each event (or once per frame), drain UI actions:

```zig
while (ui.popAction()) |action| switch (action) {
    .RestartSession => |idx| try sessions[idx].restart(),
    .RequestCollapseFocused => { /* start collapsing animation */ },
}
```

### 3.3 Per-frame update + render

Each frame:

* `ui.update(&host);` then drain actions.
* Render order:

  1. `renderer_mod.render(...)` (scene)
  2. `ui.render(&host, renderer)` (UI overlay)
  3. `SDL_RenderPresent`

Remove these calls from `main`:

* `renderer_mod.renderToastNotification(...)`
* `renderer_mod.renderHelpButton(...)`
* `renderer_mod.renderEscapeIndicator(...)`

---

## 4) Port the “?” help button + overlay into a component ✅

Add:

* `src/ui/components/help_overlay.zig`

Move logic from:

* `app_state.HelpButtonAnimation`
* mouse click handling currently in `main` (toggle + outside click closes)
* `renderer.renderHelpButton(...)` drawing

Component behavior:

* Internal state: `{ Closed, Expanding, Open, Collapsing }`
* Tween size from small->large using `anim/easing`.
* Hit-test:

  * click on button toggles open/close
  * click outside when open collapses
* Consume mouse clicks when:

  * click is inside help rect
  * help is open (it’s an overlay; it should capture clicks to prevent grid selection underneath)

Implementation notes:

* Keep the existing shortcut list rendering as-is, just moved.
* Give this component high `z_index` (e.g., 1000).

Acceptance checks:

* Clicking “?” opens/closes.
* When open, clicking inside does not trigger grid session expansion.
* When open, clicking outside closes it (and does not expand a grid cell that frame).

---

## 5) Port toast notifications into a component (and fix the per-frame TTF cost)

Add:

* `src/ui/components/toast.zig`

Move from:

* `app_state.ToastNotification`
* `renderer.renderToastNotification(...)`

Critical improvement: texture caching

* Current approach creates a TTF font + surface + texture every frame.
* New component owns:

  * `ttf_font: ?*TTF_Font`
  * `texture: ?*SDL_Texture`
  * `tex_w/tex_h`
  * `message` + `message_len`
  * `dirty` flag when message changes
* Rebuild texture only when `show(message)` is called (or when font size changes).
* Alpha fade can stay time-based without rebuilding the texture.

Expose a simple method on `UiRoot`:

* `ui.toast(message)` or `ui.showToast(message)` that forwards to the toast component.

Acceptance checks:

* Toast still appears and fades.
* No repeated TTF_OpenFont per frame (only at first use / when needed).

---

## 6) Port ESC long-hold indicator into a reusable “hold gesture” component

Add:

* `src/ui/gestures/hold.zig` (reusable)
* `src/ui/components/escape_hold.zig`

Gesture primitive:

```zig
pub const HoldGesture = struct {
    active: bool,
    start_ms: i64,
    duration_ms: i64,
    consumed: bool,

    pub fn start(now: i64) void
    pub fn stop() void
    pub fn progress(now: i64) f32 // 0..1
    pub fn isComplete(now: i64) bool
};
```

EscapeHold component:

* On `KEY_DOWN Escape` (non-repeat) when `input.canHandleEscapePress(view_mode)` is true:

  * start gesture
  * consume the keydown (so app doesn’t treat it as terminal input)
* On `KEY_UP Escape`:

  * if complete OR consumed: consume keyup
  * else: do not consume (so `main` can send ESC to the terminal like it does now)
* On update:

  * if active and becomes complete and not yet consumed:

    * push `UiAction.RequestCollapseFocused`
    * mark gesture consumed (prevents repeat firing)
* Render:

  * move `renderEscapeIndicator(...)` code here
  * component has high `z_index` but below help overlay

Acceptance checks:

* Holding ESC triggers collapse exactly once.
* Quick press+release still sends ESC to the focused terminal.
* The indicator renders only when active.

---

## 7) Port “Restart” as a UI component (drawing + hit testing)

Add:

* `src/ui/components/restart_buttons.zig`

What it replaces:

* click detection in `main` that calls `renderer_mod.getRestartButtonRect(...)` + `isPointInRect(...)`
* rendering in `renderer.renderSessionOverlays(...)` that draws the restart button texture per dead session

Component design:

* Active only when `view_mode == .Grid`.
* Needs:

  * grid layout info (cell size, cols/rows)
  * per-session dead info
* Draw pass:

  * for each session cell where `dead == true`, draw the restart button at bottom-right of that cell.
* Input:

  * on mouse down, compute clicked cell index (same math as main currently)
  * if that session is dead, compute restart button rect and if inside:

    * push `UiAction.RestartSession(idx)`
    * consume event
  * otherwise do not consume (so grid click-to-expand stays handled by app)

Critical cleanup: share one “Restart” label texture

* Remove per-session cached fields (`restart_button_texture`, `restart_button_w/h`) from `SessionState`.
* The component owns:

  * `ttf_font_small`
  * `restart_texture`
  * `tex_w/tex_h`
* This makes the button consistent and removes session-level UI baggage.

Then:

* Remove from `renderer.zig`:

  * `isPointInRect`
  * `getRestartButtonRect`
  * the restart drawing block in `renderSessionOverlays`

Acceptance checks:

* Restart buttons still appear for dead sessions.
* Clicking Restart restarts that session.
* Clicking elsewhere on the cell still expands it (existing app behavior preserved).
* No session-level restart texture lifecycle code remains.

---

## 8) Cleanup passes

### 8.1 Remove UI types from `app_state.zig`

Delete or relocate:

* `ToastNotification`
* `HelpButtonAnimation` + `HelpButtonState`
* `EscapeIndicator`
* UI constants: notification timings, help sizes, ESC arc counts, etc

Keep in `app_state.zig`:

* view/animation state for the scene (`AnimationState`, `ViewMode`, etc)

### 8.2 Remove UI render functions from `renderer.zig`

Delete:

* `renderToastNotification`
* `renderHelpButton`
* `renderEscapeIndicator`
* `isPointInRect`, `getRestartButtonRect`

Renderer remains:

* Scene render + any *scene* overlays (borders, attention highlight, scroll indicator, etc)

---

## 9) Suggested commit/order strategy (keeps the build green)

1. Add `geom.zig`, `anim/easing.zig`, `gfx/primitives.zig` and update imports (no behavior change).
2. Add `ui/` framework skeleton + integrate into main (still no UI components, render is empty).
3. Port HelpOverlay component (remove old handling + rendering).
4. Port Toast component (remove old toast rendering, add caching).
5. Port EscapeHold component (remove old escape_indicator state + rendering, keep terminal ESC behavior).
6. Port RestartButtons overlay (remove old click detection + renderer restart drawing; remove session restart texture fields).
7. Final cleanup in `app_state.zig` and `renderer.zig`.

---

## 10) “Next components” that become trivial after this

Once the framework exists, these become clean additions (no `main.zig` edits):

* `MarqueeLabel` component (extract marquee logic from wherever you scroll long text now; reuse in CWD bar, toasts, etc).
* `Button` + `LongHoldFeedback` reusable primitives (so Restart and other buttons share consistent visuals/behavior).
* Simple scene-independent “overlay panel” component (help overlay becomes a specific instance).
