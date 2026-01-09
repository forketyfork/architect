# Architect - Terminal Wall

[![Build status](https://github.com/forketyfork/architect/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/architect/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)

![Architect Hero](docs/assets/architect-hero.png)

A Zig terminal multiplexer that displays 9 interactive terminal sessions in a 3×3 grid with smooth expand/collapse animations. Built on ghostty-vt for terminal emulation and SDL3 for rendering.

> [!WARNING]
> **This project is in early stages of development. Use at your own risk.**
>
> The application is experimental and may have bugs, stability issues, or unexpected behavior. See [Known Limitations](#known-limitations) for current shortcomings.

![Architect Demo](docs/assets/architect-demo.gif)

## Installation

### Download Pre-built Binary (macOS)

Download the latest release from the [releases page](https://github.com/forketyfork/architect/releases).

**For Apple Silicon (M1/M2/M3/M4):**
```bash
curl -LO https://github.com/forketyfork/architect/releases/latest/download/architect-macos-arm64.tar.gz
tar -xzf architect-macos-arm64.tar.gz
xattr -dr com.apple.quarantine Architect.app
open Architect.app
```

**For Intel Macs:**
```bash
curl -LO https://github.com/forketyfork/architect/releases/latest/download/architect-macos-x86_64.tar.gz
tar -xzf architect-macos-x86_64.tar.gz
xattr -dr com.apple.quarantine Architect.app
open Architect.app
```

**Note**:
- The archive contains `Architect.app`. You can launch it with `open Architect.app` or run `./Architect.app/Contents/MacOS/architect` from the terminal. Keep the bundle contents intact.
- Not sure which architecture? Run `uname -m` - if it shows `arm64`, use the ARM64 version; if it shows `x86_64`, use the Intel version.

### Homebrew (macOS)

**Prerequisites**: Xcode Command Line Tools must be installed:
```bash
xcode-select --install
```

Install via Homebrew (builds from source):

```bash
# Tap the repository (note: requires full repo URL since the formula is in the main repo)
brew tap forketyfork/architect https://github.com/forketyfork/architect

# Install architect
brew install architect

# Copy the app to your Applications folder
cp -r $(brew --prefix)/Cellar/architect/*/Architect.app /Applications/
```

Or install directly without tapping:

```bash
brew install https://raw.githubusercontent.com/forketyfork/architect/main/Formula/architect.rb
cp -r $(brew --prefix)/Cellar/architect/*/Architect.app /Applications/
```

The formula will:
- Build from source using Zig
- Install all required dependencies (SDL3, SDL3_ttf)
- Create Architect.app with bundled fonts and icon
- After copying to /Applications, launch from Spotlight or: `open -a Architect`

### Build from Source

See [Setup](#setup) section below for building from source.

## Features

- **3×3 Terminal Grid**: Run 9 independent shell sessions simultaneously
- **Smooth Animations**: Click any terminal to smoothly expand it to full screen
- **Full-Window Scaling**: Each terminal is sized for the full window and scaled down in grid view
- **Resizable Window**: Dynamically resize the window with automatic terminal and PTY resizing
- **Real-Time I/O**: Non-blocking PTY communication with live updates
- **Interactive Control**:
  - Click any grid cell or press ⌘+Return in grid view to expand
  - Hold Esc for ~700ms to collapse back to grid; a quick tap is forwarded to the terminal
  - Type in the focused terminal
- **Keyboard Navigation**: Move the grid focus with ⌘↑/↓/←/→ and open the on-screen shortcut overlay via the ? pill in the top-right corner
- **Scrollback in Place**: Hover any terminal and use the mouse wheel to scroll history; typing snaps back to live output and a yellow strip in grid view shows when you're scrolled
- **High-Quality Rendering**: SDL_ttf font rendering with bundled Victor Mono Nerd Font (ligatures enabled), glyph caching, vsynced presentation, and cached grid tiles to reduce redraw work
- **Persistent Configuration**: Automatically saves and restores font size, window dimensions, and window position
- **Font Size Adjustment**: Use Cmd+Plus/Minus (8–96px) to adjust font size (saved automatically)
- **Link Opening**: Cmd+Click on OSC 8 hyperlinks to open them in your default browser (cursor changes to pointer when hovering over links with Cmd held)
- **Claude-friendly hooks**: Unix domain socket for notifying Architect when a session is waiting for approval or finished; grid tiles highlight with a fat yellow border
- **Session Recovery**: A `Restart` button appears on any grid tile whose shell exited, letting you respawn that session without quitting the app
- **Working Directory Bar**: Grid tiles show the session’s current working directory with a marquee for long paths

## Prerequisites

- Nix with flakes enabled

## Setup

1. (Optional) Pre-fetch the ghostty dependency to speed up the first build:
   ```bash
   just setup
   ```
   `just setup` caches the `ghostty` source tarball; the regular build will fetch it automatically if you skip this step.

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

## Configuration

Architect automatically saves your preferences to `~/.config/architect/config.toml`. The configuration includes:

- **Font size**: Adjusted via Cmd+Plus/Minus shortcuts (range: 8-32px, default: 14px)
- **Window dimensions**: Automatically saved when you resize the window
- **Window position**: Saved along with window dimensions when you resize or adjust font size

The configuration file is created automatically on first use and updated whenever settings change. No manual editing required.
Existing `config.json` files from older versions are automatically migrated to TOML on next launch.

**Example configuration:**
```toml
font_size = 16
window_width = 1920
window_height = 1080
window_x = 150
window_y = 100
```

To reset to defaults, simply delete the configuration file:
```bash
rm ~/.config/architect/config.toml
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

### UI/Rendering helpers

- Geometry + hit testing helpers live in `src/geom.zig`.
- Shared easing functions live in `src/anim/easing.zig`.
- Rounded/thick border drawing helpers live in `src/gfx/primitives.zig`; use these instead of redefining SDL primitives in new UI components.
- The UI framework entrypoint is `src/ui/`: `UiRoot` handles event dispatch, per-frame updates, and overlay rendering for registered UI components.
- Architecture and layering overview: see `docs/architecture.md`.
- For scrolling text overlays, reuse `src/ui/components/marquee_label.zig`.

## AI Assistant Integration

Architect integrates with AI coding assistants through a Unix domain socket protocol. Grid tiles automatically highlight when an assistant is waiting for approval (pulsing yellow border) or has completed a task (solid green border).

### Socket Protocol

- **Notification socket**: Architect listens on `${XDG_RUNTIME_DIR:-/tmp}/architect_notify_<pid>.sock` (Unix domain socket, mode 0600, where `<pid>` is the process ID).
- **Per-shell env**: Each spawned shell receives `ARCHITECT_SESSION_ID` (0‑based grid index) and `ARCHITECT_NOTIFY_SOCK` (socket path) so tools inside the terminal can send status.
- **Protocol**: Send a single-line JSON object to the socket:
  - `{"session":0,"state":"start"}` clears the highlight and marks the session as running.
  - `{"session":0,"state":"awaiting_approval"}` turns on a pulsing yellow border in the 3×3 grid (request).
  - `{"session":0,"state":"done"}` shows a solid green border in the grid (completion).

**Example from inside a terminal session:**
```bash
python - <<'PY'
import json, socket, os
sock = os.environ["ARCHITECT_NOTIFY_SOCK"]
msg = json.dumps({"session": int(os.environ["ARCHITECT_SESSION_ID"]), "state": "awaiting_approval"}) + "\n"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(msg.encode())
s.close()
PY
```

**Example from outside (host):**
```bash
# Find the socket (PID is included in the filename)
SOCK=$(ls ${XDG_RUNTIME_DIR:-/tmp}/architect_notify_*.sock 2>/dev/null | head -1)

# Send notification for session 0
python - <<PY
import json, socket, os
sock = os.environ["SOCK"]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(json.dumps({"session":0,"state":"done"}).encode() + b"\n")
s.close()
PY
```

### Configuring Claude Code Hooks

To automatically send notifications when Claude Code stops or requests approval:

1. Copy the `architect_notify.py` script from the repository root to your Claude config directory:
   ```bash
   cp architect_notify.py ~/.claude/architect_notify.py
   chmod +x ~/.claude/architect_notify.py
   ```

   This script is included in the Architect repository and handles notifications for all supported AI assistants.

2. Add hooks to your `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 ~/.claude/architect_notify.py done || true"
             }
           ]
         }
       ],
       "Notification": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 ~/.claude/architect_notify.py awaiting_approval || true"
             }
           ]
         }
       ]
     }
   }
   ```

3. Run Architect and start Claude Code in one of the terminal sessions. The grid cell will automatically highlight when Claude requests approval or completes a task.

### Configuring Codex Hooks

To automatically send notifications when Codex requests approval or completes a task:

1. Create a notification script at `~/.codex/notify.py`:
   ```python
   #!/usr/bin/env python3
   import json, os, subprocess, sys

   HOME = os.environ.get("HOME", "")
   ARCHITECT_NOTIFY = [
       "python3",
       os.path.join(HOME, "path/to/architect/architect_notify.py"),
   ]

   def route_to_architect(notification: dict) -> None:
       ntype = (notification.get("type") or "").lower()
       state = None

       if ntype == "agent-turn-complete":
           state = "done"
       elif "approval" in ntype or "permission" in ntype:
           state = "awaiting_approval"
       elif "input" in ntype and "await" in ntype:
           state = "awaiting_approval"

       if state is None:
           return

       try:
           subprocess.run(ARCHITECT_NOTIFY + [state], check=False)
       except Exception:
           pass

   def main() -> int:
       notification = json.loads(sys.argv[1])
       route_to_architect(notification)
       return 0

   if __name__ == "__main__":
       sys.exit(main())
   ```

2. Update the path to `architect_notify.py` in the script to match your repository location.

3. Add the `notify` setting to your `~/.codex/config.toml`:
   ```toml
   notify = ["python3", "/Users/your-username/.codex/notify.py"]
   ```

4. Run Architect and start Codex in one of the terminal sessions. The grid cell will automatically highlight when Codex requests approval or completes a task.

### Configuring Gemini CLI Hooks

To automatically send notifications when Gemini CLI requests approval or completes a task:

1. Copy the notification scripts from the repository:
   ```bash
   cp architect_notify.py ~/.gemini/architect_notify.py
   cp architect_hook_gemini.py ~/.gemini/architect_hook.py
   chmod +x ~/.gemini/architect_notify.py ~/.gemini/architect_hook.py
   ```

   **Note**: Gemini CLI hooks require special handling because they receive JSON via stdin and must output JSON to stdout. The `architect_hook.py` wrapper handles this protocol and calls the shared `architect_notify.py` script.

2. Add hooks to your `~/.gemini/settings.json`:
   ```json
   {
     "hooks": {
       "AfterAgent": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "architect-completion",
               "type": "command",
               "command": "python3 ~/.gemini/architect_hook.py done",
               "description": "Notify Architect when task completes"
             }
           ]
         }
       ],
       "Notification": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "architect-approval",
               "type": "command",
               "command": "python3 ~/.gemini/architect_hook.py awaiting_approval",
               "description": "Notify Architect when waiting for approval"
             }
           ]
         }
       ]
     },
     "tools": {
       "enableHooks": true
     }
   }
   ```

   **Important**: The `"tools": {"enableHooks": true}` setting is required to enable hooks in Gemini CLI.

3. Run Architect and start Gemini CLI in one of the terminal sessions. The grid cell will automatically highlight when Gemini requests approval or completes a task.

**Note**: Gemini CLI hooks use a different protocol than Claude Code and Codex. The `matcher` field is required, and hooks must read JSON from stdin and output JSON to stdout. See the [Gemini CLI hooks documentation](https://geminicli.com/docs/hooks/) for more details.

## Releases

macOS release binaries are automatically built for both ARM64 (Apple Silicon) and x86_64 (Intel) architectures via GitHub Actions when a version tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Each release includes:
- `architect-macos-arm64.tar.gz` - For Apple Silicon Macs (M1/M2/M3/M4)
- `architect-macos-x86_64.tar.gz` - For Intel Macs

Download the latest release from the [releases page](https://github.com/forketyfork/architect/releases).

## Project Structure

- `src/main.zig` - Main application with SDL3 event loop and animation system
- `src/shell.zig` - Shell process spawning and management
- `src/pty.zig` - PTY abstractions and utilities
- `src/font.zig` - Font rendering with SDL_ttf and glyph caching
- `src/font_paths.zig` - Font path resolution for bundled fonts
- `src/config.zig` - Configuration persistence (saves font size, window size, and position)
- `src/c.zig` - C library bindings for SDL3
- `assets/fonts/` - Bundled Victor Mono Nerd Font files (installed to share/architect/fonts)
- `build.zig` - Zig build configuration with SDL3 dependencies
- `build.zig.zon` - Zig package dependencies
- `docs/` - Documentation and implementation plans
- `justfile` - Convenient command shortcuts
- `flake.nix` - Nix development environment
- `.github/workflows/` - CI/CD workflows (build and release)

## Dependencies

- **ghostty-vt**: Terminal emulation library from `ghostty-org/ghostty`, fetched as a pinned tarball via Zig package manager (see `build.zig.zon`)
  - Provides terminal state machine and ANSI escape sequence parsing
- **SDL3**: Window management and rendering backend (via Nix)
- **SDL3_ttf**: Font rendering library (via Nix)
- **Victor Mono Nerd Font**: Bundled monospace font with programming ligatures
  - Licensed under SIL Open Font License 1.1 (see `assets/fonts/LICENSE`)
  - Includes Nerd Font icons for enhanced terminal experience

## Architecture

### Terminal Scaling
Each terminal session is initialized with full-window dimensions (calculated from font metrics). In grid view, these full-sized terminals are scaled down to 1/3 and rendered into grid cells, providing a "zoomed out" view of complete terminal sessions.

### Animation System
The application uses cubic ease-in-out interpolation to smoothly transition between grid and full-screen views over 300ms. Six view modes (Grid, Expanding, Full, Collapsing, PanningLeft, PanningRight) manage the animation state, including horizontal panning for terminal switching.

### Rendering Pipeline
1. Font glyphs are rendered to cached SDL textures
2. Terminal cells are iterated and glyphs drawn at scaled positions
3. Content is clipped to grid cell boundaries
4. Borders indicate focus state

## Implementation Status

✅ **Fully Implemented**:
- 3×3 grid layout with 9 terminal sessions
- PTY management and shell spawning
- Real-time terminal I/O
- SDL3 window and event loop with resizable window support
- Font rendering with SDL_ttf
- Click-to-expand interaction
- Smooth expand/collapse animations
- Keyboard input handling
- Full-window terminal scaling
- Dynamic terminal and PTY resizing on window resize
- Persistent configuration (font size, window size, and position)
- Font size adjustment via keyboard shortcuts (Cmd+Plus/Minus)
- Claude Code integration via Unix domain sockets
- Scrolling back through terminal history (mouse wheel) with a grid indicator when a pane is scrolled
- Text selection in full view with clipboard copy/paste (drag, ⌘C / ⌘V)
- Cmd+Click to open hyperlinks (OSC 8) in your default browser

## Known Limitations

The following features are not yet fully implemented:
- **Emoji coverage is macOS-only**: Apple Color Emoji fallback is used; other platforms may still show tofu or monochrome glyphs for emoji and complex ZWJ sequences.
- **No font selection**: Victor Mono font is bundled with the application (though size is adjustable)
- **Limited configurability**: Grid size, colors, and keybindings are hardcoded

## License

MIT
