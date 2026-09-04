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

   On macOS hosts where the active `MacOSX.sdk` only exposes `arm64e` targets, the Zig 0.16.0 dev shell retains a workaround for native Darwin linking errors such as `undefined symbol: __availability_version_check`. The upstream tracker for this regression is https://codeberg.org/ziglang/zig/issues/31756.

   The dev shell works around that by exposing `MacOSX15.4.sdk` through a fake `DEVELOPER_DIR` whose `usr/bin/xcrun` is a narrow shim for `xcrun --sdk macosx --show-sdk-path`. `build.zig` also resolves framework paths through `DEVELOPER_DIR` and `xcrun` before it falls back to hardcoded SDK locations, so the workaround does not need to force `SDKROOT`. Keeping the shim inside the fake developer tree means tools like `git` can still invoke `/usr/bin/xcrun` without tripping over the overridden `DEVELOPER_DIR`.

   Keep this workaround until a macOS host confirms that Zig handles the arm64e-only SDK stubs correctly. If the active `MacOSX.sdk/usr/lib/libSystem.tbd` advertises `arm64-macos` again, the shell hook becomes a no-op.

   The Homebrew formula sources the same helper while building from source, so Homebrew installs receive the SDK selection even though they do not run inside the Nix development shell.

3. Verify the environment:
   ```bash
   zig version  # Should show 0.16.0+ (compatible with ghostty-vt)
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

Run with a custom log directory (see `docs/configuration.md` for logging details):
```bash
just run --log-dir .tmp/architect-debug-logs
# or
zig build run -- --log-dir .tmp/architect-debug-logs
```

## Dependencies and Tooling

- **ghostty-vt** is fetched as a pinned tarball via the Zig package manager (`build.zig.zon`).
- **Zwanzig v0.15.1** is pinned as a Zig build dependency and runs as a host-targeted `ReleaseFast` build tool through `zig build lint`. Architect passes its requested target architecture and operating system to Zwanzig for target-aware analysis.
- **SDL3** and **SDL3_ttf** are provided by Nix. SDL3 is pinned to 3.4.10 via `overlays/sdl3-3-4-10.nix` with binaries cached in the public `forketyfork` Cachix to avoid rebuilds.

SDL3 and the platform C APIs are translated at build time with Zig's built-in
`addTranslateC` steps using the small header shims under `src/c/`. When SDL is
provided outside the compiler's default search paths, `SDL3_INCLUDE_PATH` and
`SDL3_TTF_INCLUDE_PATH` supply the include paths to both translation and
compilation. The Homebrew formula sets these variables from the installed SDL
formula prefixes before starting the build. On macOS, framework headers use
the SDK path discovered from `SDKROOT`, `DEVELOPER_DIR`, or `xcrun`, in that
order.

## Tests and Formatting

Run tests:
```bash
just test
# or
zig build test
```

Tests live next to the code they cover. Zig only collects tests from files it
actually analyzes, so **a new file with tests must be listed in the
`test { _ = @import(...); }` block at the bottom of `src/main.zig`** — otherwise
its tests compile but silently never run. `scripts/check-test-registry.sh`
(part of `just lint`) fails the build when a file with tests is missing from
that block.

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

The release workflow packages ad-hoc-signed app bundles with local `codesign --sign -`. It does not import macOS signing certificates, does not produce Developer ID-signed artifacts, and does not notarize the app. Release downloads therefore still require clearing the quarantine attribute after extraction, as described in the README installation instructions. You can also run the Release workflow manually with `workflow_dispatch` to validate the packaging flow before pushing a real release tag.

Each release includes:
- `architect-macos-arm64.tar.gz` - Apple Silicon
- `architect-macos-x86_64.tar.gz` - Intel

Each archive contains `Architect.app` with both `Contents/MacOS/architect` and the stdio MCP helper `Contents/MacOS/architect-mcp`.
