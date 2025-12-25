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

The project currently consists of:
- Basic Zig executable that imports ghostty-vt module
- Build system configured to use ghostty as a path dependency
- Application prints a simple message confirming ghostty-vt module loads successfully
- No windowing, rendering, or PTY management yet implemented

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

- `src/main.zig` - Main application entry point (currently minimal)
- `build.zig` - Zig build configuration with ghostty-vt module import
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

### Multi-Terminal Grid Architecture

For the 3×3 grid, the application will need:
- Data structure managing 9 independent `ghostty_vt.Terminal` instances
- 9 separate PTY handles and shell processes
- Layout manager computing grid cell rectangles based on window size
- Render loop iterating over sessions and blitting to grid cells
- Focus manager tracking selected session
- Animation system for smooth transitions between grid and fullscreen views

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
