# Architecture Overview

Architect is organized around three layers: platform input/output, scene rendering, and a UI overlay powered by a small retained-ish component registry.

## Runtime Flow
- **main.zig**: owns application lifetime, window sizing, PTY/session startup, configuration persistence, and the frame loop. Each frame it:
  1. Polls SDL events.
  2. Builds a lightweight `UiHost` snapshot and lets `UiRoot` handle events first.
  3. Runs remaining app logic (terminal input, resizing, notifications).
  4. Calls `renderer.render` for the scene, then `ui.render` for overlays, then presents.
- **renderer/render.zig**: draws only the *scene* (terminals, borders, attention tint, grid/full animations). It has no UI hit-testing or UI-specific textures.
- **UiRoot (src/ui/)**: registry of UI components. Dispatches events topmost-first, updates components, drains `UiAction`s, and renders UI last.

## Key Modules
- `src/ui/components/`: individual overlay pieces (`help_overlay`, `toast`, `escape_hold`, `restart_buttons`).
- `src/ui/gestures/`: reusable input gestures (`hold`).
- `src/gfx/primitives.zig`: shared rounded/thick border drawing helpers.
- `src/geom.zig`: shared `Rect` + hit-testing.
- `src/anim/easing.zig`: shared easing functions.

## Data & State Boundaries
- Scene state lives in session/app files (`src/session/*`, `src/app/app_state.zig`).
- UI-specific state lives inside components under `src/ui/`; scene code must not own UI state.
- `UiHost` is a read-only snapshot that UI consumes each frame; it mirrors only what UI needs (window size, grid layout, view mode, per-session dead/spawned flags, time).
- `UiAction` is the only way UI mutates the app (e.g., `RestartSession`, `RequestCollapseFocused`).

## Input Routing
- SDL events enter `main.zig`, which immediately builds `UiHost` and calls `ui.handleEvent`. If a component consumes the event, the app’s legacy handlers are skipped for that event.
- ESC long-hold, help toggle, restart clicks, and future UI interactions live entirely in UI components; `main.zig` should not reimplement their hit-testing.

## Rendering Order
1. Scene: `renderer.render(...)`
2. UI overlay: `ui.render(...)`
3. Present: `SDL_RenderPresent`

## Invariants (high-level)
- UI input/rendering goes through `UiRoot`; `main.zig` and `renderer.zig` stay scene-focused.
- No UI state or textures stored on sessions or in `app_state.zig`.
- Renderer never draws help/toast/ESC/restart UI; those belong to `src/ui/components/`.
- New UI pieces register with `UiRoot`; they do not add new event branches in `main.zig`.
