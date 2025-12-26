# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Architect is a Zig application that demonstrates a 3×3 grid of interactive terminal sessions with smooth animations, built on top of ghostty-vt. Currently, the project is in early development with basic scaffolding and dependency configuration in place.

## Development Environment Setup

This project uses Nix flakes for reproducible development environments:

```bash
# Clone the ghostty dependency (first time only)
just setup

# Enter development shell
nix develop

# Or with direnv
direnv allow
```

The Nix flake provides:
- Zig master branch (from mitchellh/zig-overlay)
- just command runner

## Build Commands

```bash
# Clone ghostty dependency (first time setup)
just setup

# Build the project
zig build
# or
just build

# Run the application
zig build run

# Run tests
zig build test
# or
just test

# Check code formatting
zig fmt --check src/
# or
just lint

# Format code
zig fmt src/

# Run all CI checks (build, test, lint)
just ci
```

## Architecture

### Current State

The project is a fully functional terminal multiplexer with:
- **3×3 grid layout** displaying 9 independent terminal sessions
- **SDL2-based rendering** with SDL_ttf for font rendering
- **PTY management** spawning real shell processes for each session
- **Interactive animations** with smooth expand/collapse transitions
- **Full-window terminals scaled to grid cells** - each terminal is sized for the full window and scaled down to 1/3 when displayed in the grid
- **Click-to-expand** - clicking any grid cell smoothly expands it to full screen
- **Keyboard support** - ESC key collapses expanded sessions back to grid view
- **Real-time I/O** - non-blocking PTY reading with live terminal updates

### Dependency Management

The project depends on **ghostty-vt**, a production-grade terminal emulation library extracted from Ghostty. This dependency is configured as a **path dependency** pointing to `ghostty/` directory (gitignored).

Key dependency details:
- The official `ghostty-org/ghostty` repository is cloned locally using `just setup`
- Configured in `build.zig.zon` as a path dependency pointing to `ghostty/`
- Imported in `build.zig` via `lazyDependency()` mechanism
- The ghostty-vt module provides terminal emulation core without rendering or PTY management
- API is explicitly unstable and subject to change
- CI automatically clones the dependency from `ghostty-org/ghostty`

### Project Structure

- `src/main.zig` - Main application with SDL2 event loop, animation system, and rendering
- `src/shell.zig` - Shell process spawning and management
- `src/pty.zig` - PTY (pseudo-terminal) abstractions and utilities
- `src/font.zig` - Font rendering with SDL_ttf and glyph caching
- `src/c.zig` - C library bindings for SDL2 and SDL_ttf
- `build.zig` - Zig build configuration with ghostty-vt module and SDL2 dependencies
- `build.zig.zon` - Package manifest with ghostty path dependency
- `docs/ghostty-vt-notes.md` - Comprehensive integration documentation for ghostty-vt
- `docs/terminal-wall-plan.md` - Implementation plan documentation
- `justfile` - Command shortcuts for common development tasks
- `flake.nix` - Nix development environment configuration

### ghostty-vt Integration Architecture

**What ghostty-vt provides:**
- Terminal emulation core (ANSI escape sequences, terminal state)
- Screen state management (grid of cells, scrollback)
- Input encoding (keyboard events → terminal sequences)
- Zero dependencies when SIMD disabled; only libc/libcpp with SIMD

**What must be implemented separately:**
- **PTY management**: Creating pseudo-terminals and spawning shells
- **Rendering**: Choosing windowing backend (SDL2, GLFW, etc.) and drawing terminal grid
- **Event loop**: Polling PTY output, keyboard/mouse input, and driving animations

**Integration flow:**
1. Create Terminal instance with geometry (`ghostty_vt.Terminal.init()`)
2. Create PTY and spawn shell (use system APIs, not provided by ghostty-vt)
3. Read PTY output → feed to terminal via `vtStream().nextSlice()`
4. Handle keyboard input → encode via `input.encodeKey()` → write to PTY
5. Render loop: extract cell grid from terminal → draw to window

### Multi-Terminal Grid Architecture (Implemented)

The application implements a 3×3 grid with the following components:

**Terminal Management:**
- `SessionState` struct managing each terminal instance, shell process, and PTY
- Each terminal is initialized with full-window dimensions (calculated from font metrics)
- Terminals report full-window size to shells, providing proper sizing information

**Rendering System:**
- Each grid cell displays a full-window terminal scaled down to 1/3
- Terminals render from top-left of their rect (not centered)
- Scale factor applied directly to font cell dimensions
- Bounds checking clips content to rect boundaries
- Font glyphs cached in textures for performance

**Animation System:**
- Four view modes: Grid, Expanding, Full, Collapsing
- Cubic ease-in-out interpolation for smooth transitions
- 300ms animation duration
- Real-time rect interpolation between grid cell and full window

**Input Handling:**
- Mouse clicks detect grid cell selection and trigger expansion
- ESC key collapses expanded sessions back to grid
- Keyboard input encoded to ANSI sequences and written to active PTY
- Non-blocking PTY reads avoid blocking the event loop

## Zig Version

Minimum Zig version: **0.15.2** (specified in `build.zig.zon`)

The Nix flake provides Zig master branch, which is compatible with ghostty-vt's requirements (0.15.2+).

## ghostty-vt Reference

For detailed ghostty-vt integration patterns, API overview, and usage examples, see `docs/ghostty-vt-notes.md`. Key sections:
- Build requirements and dependency configuration
- API overview (Terminal, Screen, Parser, input encoding)
- PTY integration patterns (not provided by ghostty-vt)
- Rendering integration patterns (not provided by ghostty-vt)
- Memory management considerations

The ghostty repository at `ghostty/` contains reference implementations in:
- `src/pty.zig` - PTY lifecycle management
- `src/termio/Termio.zig` - Terminal I/O coordination
- `example/zig-vt/` - Basic terminal examples
- `example/zig-vt-stream/` - Escape sequence parsing examples

## Documentation Maintenance

**IMPORTANT**: When making significant changes to the codebase, keep both `CLAUDE.md` and `README.md` up-to-date:
- Update `CLAUDE.md` when architecture, build processes, or development workflows change
- Update `README.md` when user-facing features, setup instructions, or project status change
- Ensure both files remain consistent and accurate with the current state of the project

## Claude Code Hook

- Architect exposes a Unix domain socket at `${XDG_RUNTIME_DIR:-/tmp}/architect_notify.sock` (created at startup, chmod 600).
- Every spawned shell gets two env vars:
  - `ARCHITECT_SESSION_ID`: 0-based grid index (matches the 3×3 order).
  - `ARCHITECT_NOTIFY_SOCK`: absolute path to the socket.
- Protocol: send a single JSON line to the socket:
  - `{"session":N,"state":"start"}` → clear highlight / mark running
  - `{"session":N,"state":"awaiting_approval"}` → pulsing yellow border in grid
  - `{"session":N,"state":"done"}` → solid yellow border in grid
- Minimal Python helper Claude can run inside the session:
  ```python
  import json, os, socket
  sock = os.environ["ARCHITECT_NOTIFY_SOCK"]
  msg = json.dumps({"session": int(os.environ["ARCHITECT_SESSION_ID"]), "state": "awaiting_approval"}) + "\n"
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(sock)
  s.sendall(msg.encode())
  s.close()
  ```
