#!/usr/bin/env bash
# Rebuild Architect from the CURRENT worktree (committed + uncommitted changes)
# and relaunch it, so you never again restart a stale binary.
#
# Flow: build (debug) -> package an .app bundle -> quit the running Architect ->
# swap the fresh bundle into /Applications -> relaunch via `open`.
#
# The quit+relaunch runs in a detached subprocess (nohup/disown) so it survives
# even if this script is itself running inside the Architect being replaced.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/scripts/bundle-macos.sh" ]]; then
    echo "error: run this from inside the Architect repo (no scripts/bundle-macos.sh found)" >&2
    exit 1
fi
cd "$ROOT"

# --- Ensure a working build toolchain + SDK ---
# Preferred path: a Nix dev shell provides zig, a linkable SDK, and SDL3. If
# zig is not on PATH but nix is, re-enter the flake dev shell and re-run there.
if ! command -v zig >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        exec nix develop "$ROOT" -c "$0" "$@"
    fi
    echo "error: 'zig' is not on PATH and 'nix' is unavailable." >&2
    echo "       Install zig (or symlink it onto PATH), or run from your Nix dev shell." >&2
    exit 1
fi

# Native (Homebrew) build setup. Each line only fills in a value that isn't
# already set, so this is a no-op inside a Nix dev shell that already provides them.

# SDL3 / SDL3_ttf: build.zig reads *_INCLUDE_PATH and derives the lib dir (../lib).
if command -v brew >/dev/null 2>&1; then
    : "${SDL3_INCLUDE_PATH:=$(brew --prefix sdl3 2>/dev/null)/include}"
    : "${SDL3_TTF_INCLUDE_PATH:=$(brew --prefix sdl3_ttf 2>/dev/null)/include}"
    export SDL3_INCLUDE_PATH SDL3_TTF_INCLUDE_PATH
fi

# Zig 0.15.2 cannot link the macOS 26.x SDK family (ziglang/zig#31756). Redirect
# SDK discovery to the 15.4 SDK when present and DEVELOPER_DIR isn't already set.
legacy_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$legacy_sdk" ]; then
    wr="$ROOT/.tmp/macos-sdk-workaround"
    mkdir -p "$wr/bin" "$wr/developer/SDKs" "$wr/developer/usr/bin"
    ln -sfn "$legacy_sdk" "$wr/developer/SDKs/MacOSX.sdk"
    cat > "$wr/developer/usr/bin/xcrun" <<XCRUN
#!/bin/sh
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ] && [ "\$#" -eq 3 ]; then
    printf '%s\n' '$legacy_sdk'
    exit 0
fi
exec env DEVELOPER_DIR= /usr/bin/xcrun "\$@"
XCRUN
    chmod +x "$wr/developer/usr/bin/xcrun"
    ln -sfn "$wr/developer/usr/bin/xcrun" "$wr/bin/xcrun"
    case ":$PATH:" in
        *":$wr/bin:"*) ;;
        *) export PATH="$wr/bin:$PATH" ;;
    esac
    export DEVELOPER_DIR="$wr/developer"
fi

# Default to an optimized ReleaseFast build — this replaces your daily-driver
# /Applications app, so it must not be a slow Debug build. Pass --debug (or set
# DEV_RELOAD_DEBUG=1) only when you specifically need debug assertions/symbols.
build_debug=false
for arg in "$@"; do
    [ "$arg" = "--debug" ] && build_debug=true
done
[ -n "${DEV_RELOAD_DEBUG:-}" ] && build_debug=true

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$build_debug" = true ]; then
    echo "==> Building Architect (Debug) from '$branch' + local changes..."
    zig build
else
    echo "==> Building Architect (ReleaseFast) from '$branch' + local changes..."
    zig build -Doptimize=ReleaseFast
fi

# Build-only mode: verify the build without touching the running app.
if [ -n "${DEV_RELOAD_BUILD_ONLY:-}" ]; then
    echo "==> DEV_RELOAD_BUILD_ONLY set: built successfully, leaving the running app untouched."
    exit 0
fi

echo "==> Packaging app bundle..."
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
if [ "$build_debug" = true ]; then
    ./scripts/bundle-macos.sh zig-out/bin/architect "$staging" zig-out/bin/architect-mcp --debug
else
    ./scripts/bundle-macos.sh zig-out/bin/architect "$staging" zig-out/bin/architect-mcp
fi

# Hand the swap+relaunch to a detached process. It outlives this shell, so the
# new Architect comes up even if quitting the old one tears down our terminal.
echo "==> Quitting Architect (waiting for agents to shut down + flush) and relaunching..."
# Variables below are for the inner shell, not this one (intentional single quotes).
# shellcheck disable=SC2016
nohup bash -c '
    set -e
    staging="$1"
    # Quit gracefully and WAIT for Architect to exit on its own. This is critical
    # for the agent-resume feature: on quit, Architect Ctrl+Cs each running
    # agent so Claude flushes its session to disk before exiting. Force-killing
    # here kills the agents abruptly mid-turn — their most recent turns never
    # reach disk, so the next `claude --resume` reloads a rewound transcript.
    # So do NOT force-kill on a short timeout; give the teardown all the time it
    # needs (busy/looping agents can take tens of seconds). Re-send the quit
    # periodically in case a saturated app missed the first one. Only escalate as
    # an absolute last resort after ~5 minutes, which means the app truly hung.
    osascript -e "quit app \"Architect\"" 2>/dev/null || true
    waited=0
    while pgrep -x architect >/dev/null 2>&1 && [ "$waited" -lt 1200 ]; do
        sleep 0.25
        waited=$((waited + 1))
        if [ $((waited % 120)) -eq 0 ]; then
            osascript -e "quit app \"Architect\"" 2>/dev/null || true
        fi
    done
    if pgrep -x architect >/dev/null 2>&1; then
        # Teardown never finished after 5 min — last resort, this loses agent state.
        pkill -x architect 2>/dev/null || true
        sleep 2
        pkill -9 -x architect 2>/dev/null || true
        sleep 1
    fi
    rm -rf "/Applications/Architect.app"
    mv "$staging/Architect.app" "/Applications/Architect.app"
    rmdir "$staging" 2>/dev/null || true
    open "/Applications/Architect.app"
' _ "$staging" >/dev/null 2>&1 &
disown

# The detached job owns the staging dir now; do not let our EXIT trap delete it.
trap - EXIT

echo "==> Done. Architect will close and reopen on the fresh build."
