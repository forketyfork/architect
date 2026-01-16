# Architecture Overview

Architect is a terminal multiplexer displaying interactive sessions in a grid with smooth expand/collapse animations. It is organized around five layers: platform abstraction, input handling, session management, scene rendering, and a UI overlay system.

```
┌─────────────────────────────────────────────────────────────┐
│                         main.zig                            │
│  (application lifetime, frame loop, event dispatch)         │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Platform   │  │    Input    │  │    Notification     │  │
│  │ (SDL3 init) │  │  (mapper)   │  │   (socket thread)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Session Layer (src/session/)           │    │
│  │  SessionState: PTY, ghostty-vt terminal, xev watcher│    │
│  └─────────────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐    ┌───────────────────────────┐   │
│  │  Scene Renderer     │    │      UI Overlay System    │   │
│  │ (render/renderer)   │    │      (src/ui/*)           │   │
│  │ terminals, borders, │    │  UiRoot → components      │   │
│  │ animations, CWD bar │    │  → UiAction queue         │   │
│  └─────────────────────┘    └───────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Runtime Flow

**main.zig** owns application lifetime, window sizing, PTY/session startup, configuration persistence, and the frame loop. Each frame it:

1. Polls SDL events and scales coordinates to render space.
2. Builds a lightweight `UiHost` snapshot and lets `UiRoot` handle events first.
3. Runs remaining app logic (terminal input, resizing, keyboard shortcuts).
4. Runs `xev` loop iteration for async process exit detection.
5. Processes output from all sessions and drains async notifications.
6. Updates UI components and drains `UiAction` queue.
7. Advances animation state if transitioning.
8. Calls `renderer.render` for the scene, then `ui.render` for overlays, then presents.
9. Sleeps based on idle/active frame targets (~16ms active, ~50ms idle).

**Terminal resizing**
- `applyTerminalResize` updates the PTY size first, then resizes the `ghostty-vt` terminal.
- The VT stream stays alive; only its handler is refreshed to repoint at the resized terminal, preserving parser state and preventing in-flight escape sequences from being misparsed.

**renderer/render.zig** draws only the *scene*:
- Terminal cell content with HarfBuzz-shaped text runs
- Grid cell backgrounds and borders (focused/unfocused)
- Expand/collapse/panning animations with eased interpolation
- Attention borders (pulsing yellow for awaiting approval, solid green for done)
- CWD bar with marquee scrolling for long paths
- Scrollback indicator strip

**UiRoot (src/ui/)** is the registry for UI overlay components:
- Dispatches events topmost-first (by z-index)
- Runs per-frame `update()` on all components
- Drains `UiAction` queue for UI→app mutations
- Renders all components in z-order after the scene
- Reports `needsFrame()` when any component requires animation

**UiAssets** provides shared rendering resources:
- `FontCache` stores configured fonts keyed by pixel size, so terminal rendering and UI components reuse a single loaded font set instead of opening per-component instances.

### Session cleanup
- `main.zig` tracks how many sessions were constructed and uses a single defer to deinitialize exactly those instances on any exit path.
- `SessionState.deinit` is idempotent: textures, fonts, watchers, and buffers are nulled/cleared after destruction so double-invocation during error unwinding cannot double-free GPU resources.
- Font rendering sanitizes invalid Unicode scalars (surrogates or >0x10FFFF) to U+FFFD before shaping, preventing malformed terminal output from crashing the renderer.
- Renderer treats non-text cells (`content_tag` ≠ `.codepoint`) as empty, avoiding misinterpreting color-only cells as large codepoints that would render replacement glyphs.

## Source Structure

```
src/
├── main.zig              # Entry point, frame loop, event dispatch
├── c.zig                 # C bindings (SDL3, TTF, etc.)
├── colors.zig            # Theme and color palette management (ANSI 16/256)
├── config.zig            # TOML config persistence
├── geom.zig              # Rect + point containment
├── font.zig              # Font rendering, glyph caching, HarfBuzz shaping
├── font_cache.zig        # Shared font cache (terminal + UI)
├── font_paths.zig        # Font path resolution for system fonts
├── shell.zig             # Shell process spawning
├── pty.zig               # PTY abstractions
├── cwd.zig               # macOS working directory detection
├── url_matcher.zig       # URL detection in terminal output
├── vt_stream.zig         # VT stream wrapper for ghostty-vt
│
├── platform/
│   └── sdl.zig           # SDL3 initialization and window management
│
├── input/
│   └── mapper.zig        # Key→bytes encoding, shortcut detection
│
├── app/
│   └── app_state.zig     # ViewMode, AnimationState, SessionStatus
│
├── session/
│   ├── state.zig         # SessionState: PTY, terminal, process watcher
│   └── notify.zig        # Notification socket thread + queue
│
├── render/
│   └── renderer.zig      # Scene rendering (terminals, animations)
│
├── gfx/
│   └── primitives.zig    # Rounded/thick border drawing helpers
│
├── anim/
│   └── easing.zig        # Easing functions (cubic, etc.)
│
├── os/
│   └── open.zig          # Cross-platform URL opening
│
└── ui/
    ├── mod.zig           # Public UI module exports
    ├── root.zig          # UiRoot: component registry, dispatch
    ├── component.zig     # UiComponent vtable interface
    ├── types.zig         # UiHost, UiAction, UiAssets, SessionUiInfo
    ├── scale.zig         # DPI scaling helper
    ├── first_frame_guard.zig  # Idle throttling transition helper
    │
    ├── components/
    │   ├── button.zig            # Reusable styled button rendering helper
    │   ├── confirm_dialog.zig    # Generic confirmation dialog component
    │   ├── escape_hold.zig       # ESC hold-to-collapse indicator
    │   ├── expanding_overlay.zig # Expanding overlay animation state helper
    │   ├── global_shortcuts.zig  # Global keyboard shortcuts (e.g., Cmd+,)
    │   ├── help_overlay.zig      # Keyboard shortcut overlay (? pill)
    │   ├── hotkey_indicator.zig  # Hotkey visual feedback indicator
    │   ├── marquee_label.zig     # Reusable scrolling text label
    │   ├── pill_group.zig        # Pill overlay coordinator (collapses others)
    │   ├── quit_confirm.zig      # Quit confirmation dialog
    │   ├── restart_buttons.zig   # Dead session restart buttons
    │   ├── toast.zig             # Toast notification display
    │   └── worktree_overlay.zig  # Git worktree picker (T pill)
    │
    └── gestures/
        └── hold.zig      # Reusable hold gesture detector
```

## Asset Layout

`assets/` stores runtime assets that are embedded or packaged, including:
- `assets/macos/Architect.icns` for the macOS bundle icon
- `assets/terminfo.zig` module embedding `assets/terminfo/xterm-ghostty.terminfo` for `src/shell.zig`

## Key Types

### View Modes (`app_state.ViewMode`)
```
Grid         → 3×3 overview, all sessions visible
Expanding    → Animating from grid cell to fullscreen
Full         → Single session fullscreen
Collapsing   → Animating from fullscreen to grid cell
PanningLeft  → Horizontal pan animation (moving left)
PanningRight → Horizontal pan animation (moving right)
PanningUp    → Vertical pan animation (moving up)
PanningDown  → Vertical pan animation (moving down)
```

### Session Status (`app_state.SessionStatus`)
```
idle             → No activity
running          → Process actively running
awaiting_approval→ AI assistant waiting for user approval (pulsing border)
done             → AI assistant task completed (solid border)
```

### Animation State
- 300ms cubic ease-in-out transitions
- `start_rect` → `target_rect` interpolation
- `focused_session` and `previous_session` for panning

### Theme (`colors.zig`)
```zig
struct {
    background: SDL_Color,   // Terminal background
    foreground: SDL_Color,   // Default text color
    selection: SDL_Color,    // Selection highlight
    accent: SDL_Color,       // UI accent (focus indicators, pills)
    palette: [16]SDL_Color,  // ANSI 16-color palette
}
```
- Created from config via `Theme.fromConfig()`
- Provides `getPaletteColor(idx)` for 0-15 palette access
- `get256ColorWithTheme(idx, theme)` handles full 256-color mode (16-231: color cube, 232-255: grayscale)

### UI Component Interface
```zig
VTable {
    handleEvent: fn(*anyopaque, *UiHost, *SDL_Event, *UiActionQueue) bool
    update:      fn(*anyopaque, *UiHost, *UiActionQueue) void
    render:      fn(*anyopaque, *UiHost, *SDL_Renderer, *UiAssets) void
    hitTest:     fn(*anyopaque, *UiHost, x, y) bool
    wantsFrame:  fn(*anyopaque, *UiHost) bool
    deinit:      fn(*anyopaque, *SDL_Renderer) void
}
```

### UiAction (UI→App mutations)
```zig
union(enum) {
    RestartSession: usize,         // Restart dead session at index
    RequestCollapseFocused: void,  // Collapse current fullscreen to grid
    ConfirmQuit: void,             // Confirm quit despite running processes
    OpenConfig: void,              // Open config file (Cmd+,)
    SwitchWorktree: SwitchWorktreeAction,  // cd the focused shell into another worktree (no respawn)
    CreateWorktree: CreateWorktreeAction,  // git worktree add .architect/<name> -b <name> && cd there
    RemoveWorktree: RemoveWorktreeAction,  // Remove a git worktree
    DespawnSession: usize,         // Despawn/kill a session at index
}
```

### UiHost (read-only snapshot for UI)
```zig
struct {
    now_ms: i64,
    window_w, window_h: c_int,
    ui_scale: f32,
    grid_cols, grid_rows: usize,
    cell_w, cell_h: c_int,
    view_mode: ViewMode,
    focused_session: usize,
    focused_cwd: ?[]const u8,
    focused_has_foreground_process: bool,
    sessions: []SessionUiInfo,  // dead/spawned flags per session
    theme: *const Theme,        // Active color theme
}
```

## Data & State Boundaries

| Layer | State Location | What it contains |
|-------|----------------|------------------|
| Scene | `src/session/state.zig` | PTY, terminal buffer, scroll position, CWD, cache texture |
| Scene | `src/app/app_state.zig` | ViewMode, animation rects, focused session index |
| UI    | Component structs | Visibility flags, animation timers, cached textures |
| Shared | `UiHost` | Read-only snapshot passed each frame |

**Key rule**: Scene code must not own UI state; UI state lives inside components.

## Input Routing

1. SDL events enter `main.zig`
2. Events are scaled to render coordinates
3. `UiHost` snapshot is built
4. `ui.handleEvent()` dispatches to components (topmost-first by z-index)
5. If consumed, skip app handlers; otherwise continue to main event switch
6. `ui.hitTest()` used for cursor changes in full view
7. Text input filters out backspace control bytes (0x08/0x7f) so backspace comes from key events only

Components that consume events:
- `HelpOverlayComponent`: ⌘? pill click or Cmd+/ to toggle overlay
- `WorktreeOverlayComponent`: ⌘T pill, Cmd+T, Cmd+1–9 to cd the focused shell into a worktree; Cmd+0 opens a creation modal that builds `.architect/<name>` via `git worktree add -b <name>` and cds into it; pill is hidden when a foreground process is running; refreshes its list on every open, reads worktrees from git metadata (commondir and linked worktree dirs only), highlights rows on hover with a gradient, supports click selection, limits the list to 9 entries, and displays paths relative to the primary worktree; includes delete (×) button to remove non-root worktrees
- `EscapeHoldComponent`: ESC key down/up for hold-to-collapse
- `RestartButtonsComponent`: Restart button clicks
- `QuitConfirmComponent`: Quit confirmation dialog buttons
- `ConfirmDialogComponent`: Generic confirmation dialog (used by worktree removal, etc.)
- `PillGroupComponent`: Coordinates pill overlays (collapses one when another expands)
- `GlobalShortcutsComponent`: Handles global shortcuts like Cmd+, to open config

## Rendering Order

1. **Clear**: Background color (14, 17, 22)
2. **Scene**: `renderer.render(...)` - terminals based on view mode
3. **UI Overlay**: `ui.render(...)` - all registered components in z-order
4. **Present**: `SDL_RenderPresent`

## Session Management

Each `SessionState` contains:
- `shell`: Spawned shell process with PTY
- `terminal`: ghostty-vt terminal state machine
- `stream`: VT stream wrapper for output processing
- `process_watcher`: xev-based async process exit detection
- `cache_texture`: Cached render for grid view (dirty flag optimization)
- `pending_write`: Buffered stdin for non-blocking writes

Sessions are lazily spawned: only session 0 starts on launch; others spawn on first click/navigation.

## Notification System

External tools (AI assistants) signal state changes via Unix domain socket:
```
${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock
```

Protocol: Single-line JSON
```json
{"session": 0, "state": "awaiting_approval"}
{"session": 0, "state": "done"}
{"session": 0, "state": "start"}
```

A background thread (`notify.zig`) accepts connections, parses messages, and pushes to a thread-safe `NotificationQueue`. Main loop drains queue each frame.

## First Frame Guard Pattern

When a UI component transitions to a visible state (modal appears, gesture starts), it must render immediately even under idle throttling. Use `FirstFrameGuard`:

```zig
// On state change:
self.first_frame.markTransition();

// In wantsFrame:
return self.active or self.first_frame.wantsFrame();

// At end of render:
self.first_frame.markDrawn();
```

## Reusable UI Primitives

### Button (`button.zig`)
Renders themed buttons with three variants:
- `default`: Selection background with accent border
- `primary`: Accent fill with blue border
- `danger`: Red fill with bright-red border

### ExpandingOverlay (`expanding_overlay.zig`)
Animation state helper for pill-style overlays that expand/collapse:
- Tracks `State` (Closed, Expanding, Open, Collapsing)
- Calculates interpolated size and rect for animation frames
- Used by `HelpOverlayComponent` and `WorktreeOverlayComponent`

### ConfirmDialog (`confirm_dialog.zig`)
Generic modal confirmation dialog:
- Configurable title, message, confirm/cancel labels
- Emits a `UiAction` on confirm
- Modal overlay blocks all other input
- Used for worktree removal and other destructive actions

### PillGroup (`pill_group.zig`)
Coordinates multiple pill overlays:
- When one pill starts expanding, collapses any other open pill
- Prevents multiple overlays from being expanded simultaneously

## DPI Scaling

`src/ui/scale.zig` provides `scale(value, ui_scale)` to convert logical points to physical pixels. All UI sizing should use this for HiDPI support.

## Invariants

1. **UI routing**: All UI input/rendering goes through `UiRoot`; `main.zig` and `renderer.zig` stay scene-focused.

2. **State separation**: No UI state or textures stored on sessions or in `app_state.zig`.

3. **Renderer scope**: `renderer.zig` never draws help/toast/ESC/restart/quit UI; those belong to `src/ui/components/`.

4. **Extension pattern**: New UI features register with `UiRoot` via `UiComponent`; they do not add event branches in `main.zig`.

5. **Action-based mutation**: UI components emit `UiAction`s; they do not directly mutate app state.

6. **Lazy spawning**: Sessions spawn on demand, not at startup (except session 0).

7. **Cache invalidation**: Set `session.dirty = true` after any terminal content change.

## Dependencies

- **ghostty-vt**: Terminal emulation (VT state machine, ANSI parsing)
- **SDL3**: Window management, rendering, input
- **SDL3_ttf**: Font rendering with HarfBuzz shaping
- **xev**: Event-driven async I/O for process watching
- **System fonts**: Resolved from macOS font directories (default family is SFNSMono)
