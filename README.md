# Architect - Terminal Wall

A Zig application demonstrating a 3×3 grid of interactive terminal sessions with smooth animations, built on top of ghostty-vt.

## Prerequisites

- Nix with flakes enabled

## Setup

1. Clone the ghostty dependency:
   ```bash
   just setup
   ```

   This will clone `ghostty-org/ghostty` into the `ghostty/` directory.

2. Update the Nix flake and enter the development shell:
   ```bash
   nix flake update
   nix develop
   ```

   Alternatively, if using direnv:
   ```bash
   direnv allow
   ```

3. Verify the environment:
   ```bash
   zig version  # Should show 0.15.2+ (compatible with ghostty-vt)
   just --list  # Show available commands
   ```

## Building

Build the project:
```bash
just build
# or
zig build
```

Run the application:
```bash
zig build run
```

## Development

Run tests:
```bash
just test
# or
zig build test
```

Check code formatting:
```bash
just lint
# or
zig fmt --check src/
```

Format code:
```bash
zig fmt src/
```

## Project Structure

- `src/main.zig` - Main application entry point
- `build.zig` - Zig build configuration
- `build.zig.zon` - Zig package dependencies
- `docs/` - Documentation and implementation plans
- `justfile` - Convenient command shortcuts

## Dependencies

- **ghostty-vt**: Terminal emulation library from `ghostty-org/ghostty` (path dependency)
- Cloned locally into `ghostty/` directory (gitignored)
- Configured in `build.zig.zon` to point to the local ghostty clone

## Current Status

Step 2 of the implementation plan completed:
- ✅ Zig project scaffolded
- ✅ ghostty-vt dependency configured
- ✅ Basic main.zig imports ghostty-vt
- ✅ Build system configured with `build.zig`

Next step: Establish windowing and single terminal rendering (Step 3)
