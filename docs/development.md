# Development

This document covers local setup, build/test commands, and release steps.

## Prerequisites

- Nix with flakes enabled
- macOS: Xcode Command Line Tools if you plan to use Homebrew dependencies

## Setup

1. (Optional) Pre-fetch the ghostty dependency to speed up the first build:
   ```bash
   just setup
   ```
   `just setup` caches the `ghostty` source tarball; the regular build will fetch it automatically if you skip this step.

2. Enter the development shell:
   ```bash
   nix develop
   ```

   Or, if using direnv:
   ```bash
   direnv allow
   ```

3. Verify the environment:
   ```bash
   zig version  # Should show 0.15.2+ (compatible with ghostty-vt)
   just --list  # Show available commands
   ```

## Build and Run

Build the project:
```bash
just build
# or
zig build
```

Build optimized release:
```bash
zig build -Doptimize=ReleaseFast
```

Run the application:
```bash
just run
# or
zig build run
```

## Dependencies and Tooling

- **ghostty-vt** is fetched as a pinned tarball via the Zig package manager (`build.zig.zon`).
- **SDL3** and **SDL3_ttf** are provided by Nix. SDL3 is pinned to 3.4.0 via `overlays/sdl3-3-4-0.nix` with binaries cached in the public `forketyfork` Cachix to avoid rebuilds.

## Tests and Formatting

Run tests:
```bash
just test
# or
zig build test
```

Check formatting and script linting:
```bash
just lint
# or
zig fmt --check src/
shellcheck scripts/*.sh scripts/verify-setup.sh
ruff check scripts/*.py
```

Format code:
```bash
zig fmt src/
```

## Release Process

macOS release binaries are automatically built for both ARM64 (Apple Silicon) and x86_64 (Intel) architectures via GitHub Actions when a version tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Each release includes:
- `architect-macos-arm64.tar.gz` - Apple Silicon
- `architect-macos-x86_64.tar.gz` - Intel
