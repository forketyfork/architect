# Terminal Wall

## Common Instructions

- ALWAYS run the build, test and lint locally before committing the changes:
```shell
just build
just test
just lint
```

## Step 1: Audit ghostty-vt Capabilities And Constraints
### Status Quo
The `architect` repository is empty, and the `ghostty-org/ghostty` clone exists at `../../ghostty-org/ghostty`. No documentation on `ghostty-vt` usage is captured for this project.

### Objectives
Document the APIs, build requirements, and integration patterns for embedding `ghostty-vt` inside a Zig application.

### Tech Notes
- Use `gh pr view ghostty-org/ghostty/8840 --web` or `--json` to review the module introduction, sample code, and build instructions.
- Traverse the local `ghostty` tree for `vt` examples (`rg --files -g '*vt*'` or similar) to identify reference implementations.
- Summarize initialization flows: creating a VT instance, wiring to PTY/shell, rendering surfaces, and handling input.
- Capture any required third-party libraries (e.g., rendering backends, windowing abstractions) and note Zig version compatibility constraints.

### Acceptance Criteria
A short integration memo (`docs/ghostty-vt-notes.md`) exists in this repo describing required setup steps, relevant API calls, and external dependencies for `ghostty-vt`.

## Step 2: Scaffold Zig Project With ghostty-vt Dependency
### Status Quo
ghostty-vt usage notes exist, but there is no Zig project in the `architect` repository.

### Objectives
Create the base Zig executable project and configure `build.zig` so the app can import `ghostty-vt`.

### Tech Notes
- Run `zig init-exe` (targeting the latest stable Zig supported by `ghostty-vt`) within the repo.
- Wire the local `ghostty` checkout as a module/package dependency (e.g., `b.addModule("ghostty_vt", ...)`) pointing to the module's `build.zig.zon` or source tree as required.
- Extend the build script with run options (`zig build run`) that launch the prototype binary.
- Verify compilation by importing `ghostty-vt` in `src/main.zig` and building an empty stub.

### Acceptance Criteria
`zig build` succeeds, and the executable imports `ghostty-vt` without unresolved symbol errors.

## Step 3: Establish Windowing And Single Terminal Rendering
### Status Quo
The Zig project builds but does not open a window or render terminal content.

### Objectives
Render a single `ghostty-vt` instance inside a window, demonstrating PTY attachment and event processing.

### Tech Notes
- Choose a windowing/rendering backend supported by `ghostty-vt` (e.g., SDL2, GLFW, or the module's default glue) and add necessary build dependencies.
- Initialize the backend, create a window surface, and instantiate one `vt` session bound to `/bin/zsh` (or configurable shell) via PTY.
- Implement the render loop: poll events, forward keyboard input, refresh the surface, and draw to the window.
- Confirm terminal input/output flows correctly by issuing commands within the rendered window.

### Acceptance Criteria
Running `zig build run` opens a window displaying a live shell session powered by `ghostty-vt`, with keyboard input working.

## Step 4: Manage Multiple VT Instances In A Grid Layout
### Status Quo
The application hosts a single terminal instance and lacks layout management.

### Objectives
Extend the app to host nine independent `ghostty-vt` sessions arranged in a 3×3 grid with scaled-down rendering.

### Tech Notes
- Create a data structure to manage VT session state (session id, PTY handle, geometry, render target).
- Spawn nine shells, each with its own PTY and `vt` instance.
- Compute grid cell rectangles based on window size; downscale rendering buffers to fit each cell (letterboxing if aspect ratios mismatch).
- Update the render loop to iterate over sessions, refresh their backbuffers, and blit them into their assigned cells.

### Acceptance Criteria
The window renders nine simultaneous shell sessions in a 3×3 grid, each showing independent command output while still accepting keyboard input when focused.

## Step 5: Implement Interaction Model And Focus Management
### Status Quo
The grid renders nine sessions, but there is no pointer selection, focus tracking, or expanded view.

### Objectives
Detect pointer interaction, switch focus, and transition between grid view and a selected session in full-screen mode with animation.

### Tech Notes
- Capture mouse events from the windowing backend; map click coordinates to grid cells to determine the selected session.
- Maintain application state (`enum ViewMode { Grid, Expanding, Full, Collapsing }`) to drive rendering branches.
- Build an animation timer that interpolates the selected session's rectangle from its grid cell to full-screen (and back) using easing functions.
- Route keyboard input to the focused session only; while in grid view, optionally preview keystrokes in the selected tile.
- Handle `Esc` key to trigger collapse animation returning to the grid view.

### Acceptance Criteria
Clicking any tile smoothly animates it into full-screen focus, the shell remains interactive in that state, and pressing `Esc` animates back to the 3×3 grid.

## Step 6: Polish, Configuration, And Demo Script
### Status Quo
Core interactions work, but support tooling, configuration options, and documentation are missing.

### Objectives
Add quality-of-life improvements, minimal configuration, and documentation so the PoC is reproducible.

### Tech Notes
- Provide command-line options or a config file for shell command per tile, animation speed, and grid dimensions (defaulting to 3×3).
- Ensure graceful shutdown: terminate PTYs and close sessions cleanly on window exit.
- Add a simple demo script in `README.md` outlining build/run instructions and showcasing typical usage.
- Consider adding automated smoke tests (e.g., headless render test or unit tests for layout math) if feasible.

### Acceptance Criteria
README includes build/run instructions and configuration notes, the application shuts down cleanly, and optional tests pass via `zig build test` or equivalent.
