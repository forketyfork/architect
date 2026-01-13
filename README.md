# Architect - Terminal Wall

[![Build status](https://github.com/forketyfork/architect/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/architect/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)

![Architect Hero](docs/assets/architect-hero.png)

A Zig terminal multiplexer that displays a configurable grid of interactive terminal sessions (default 3×3) with smooth expand/collapse animations. Built on ghostty-vt for terminal emulation and SDL3 for rendering.

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
- Create Architect.app with the application icon (fonts are resolved from your system based on `config.toml`)
- After copying to /Applications, launch from Spotlight or: `open -a Architect`

### Build from Source

See [Setup](#setup) section below for building from source.

## Features

- **Configurable Grid**: Run multiple independent shell sessions; defaults to 3×3 but rows/cols are configurable (1–12) in `config.toml`
- **Smooth Animations**: Click any terminal to smoothly expand it to full screen
- **Full-Window Scaling**: Each terminal is sized for the full window and scaled down in grid view
- **Resizable Window**: Dynamically resize the window with automatic terminal and PTY resizing
- **Real-Time I/O**: Non-blocking PTY communication with live updates
- **Interactive Control**:
  - Click any grid cell or press ⌘+Return in grid view to expand
  - Hold Esc for ~700ms to collapse back to grid; a quick tap is forwarded to the terminal; the hold ring waits a short moment before appearing to avoid flashes, then runs its full fill-and-pulse animation
  - Type in the focused terminal
  - Visual feedback indicator appears briefly when hotkeys are pressed
- **Keyboard Navigation**: Move the grid focus with ⌘↑/↓/←/→ and open the on-screen shortcut overlay via the ? pill in the top-right corner
- **Scrollback in Place**: Hover any terminal and use the mouse wheel to scroll history; typing snaps back to live output and a yellow strip in grid view shows when you're scrolled (10 MB per terminal, matching Ghostty's default)
- **High-Quality Rendering**: SDL_ttf font rendering with SFNSMono (default system monospace font on macOS), glyph caching, vsync-aligned presentation (renders at display refresh rate), and cached grid tiles to reduce redraw work
- **Persistent State**: Automatically saves and restores window position/size and font size; user configuration is read-only and edited via Cmd+,
- **Font Size Adjustment**: Use Cmd+Plus/Minus (8–96px) to adjust font size (saved automatically)
- **Link Opening**: Cmd+Click on OSC 8 hyperlinks to open them in your default browser (cursor changes to pointer when hovering over links with Cmd held)
- **Claude-friendly hooks**: Unix domain socket for notifying Architect when a session is waiting for approval or finished; grid tiles highlight with a fat yellow border
- **Session Recovery**: A `Restart` button appears on any grid tile whose shell exited, letting you respawn that session without quitting the app
- **Working Directory Bar**: Grid tiles show the session’s current working directory with a marquee for long paths
- **Legible Cursor**: The block cursor keeps the underlying glyph visible for easier caret tracking
- **Hold-to-Repeat on macOS**: Holding a key repeats characters instead of showing the system accent picker, matching terminal expectations

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

Architect uses two configuration files in `~/.config/architect/`:

### User Configuration (`config.toml`)

**Read-only** user preferences that are never modified by the application. Edit via **⌘,** (Cmd+Comma) keyboard shortcut which opens the file in your default text editor.

The configuration is organized into sections:

#### Font Settings (`[font]`)
- **family**: Font family name (default: `SFNSMono` on macOS)

Note: Font **size** is stored in `persistence.toml` (see below).

#### Theme Settings (`[theme]`)
- **background**: Terminal background color as hex (default: `#0E1116`)
- **foreground**: Terminal text color as hex (default: `#CDD6E0`)
- **selection**: Selection highlight color as hex (default: `#1B2230`)
- **accent**: UI accent color as hex (default: `#61AFEF`)

#### Palette Colors (`[theme.palette]`)

The 16 ANSI colors can be customized with named parameters:

**Normal colors (0-7):**
- **black**, **red**, **green**, **yellow**, **blue**, **magenta**, **cyan**, **white**

**Bright colors (8-15):**
- **bright_black**, **bright_red**, **bright_green**, **bright_yellow**, **bright_blue**, **bright_magenta**, **bright_cyan**, **bright_white**

Each color is specified as a hex string (e.g., `"#E06C75"`).

#### Grid Settings (`[grid]`)
- **rows**: Number of terminal rows in the grid (range: 1-12, default: 3)
- **cols**: Number of terminal columns in the grid (range: 1-12, default: 3)
- **font_scale**: Proportional font scaling in grid view (range: 0.5-3.0, default: 1.0). Values greater than 1.0 render larger, more readable text but show fewer terminal rows/columns (e.g., `font_scale = 1.5`). Grid settings must be edited manually in the config file.

#### Rendering Settings (`[rendering]`)
- **vsync**: Enable vertical sync (default: `true`) - When enabled, frames render at display refresh rate

### UI Settings (`[ui]`)
- **show_hotkey_feedback**: Show visual indicator when hotkeys are pressed (default: `true`)
- **enable_animations**: Toggle UI/grid transition animations (default: `true`; set to `false` for instant view changes)

A default configuration file is created automatically on first launch if it doesn't exist. User-editable settings live in `config.toml`; runtime state such as window position/size and font size is stored separately in `persistence.toml`.

### Runtime Persistence (`persistence.toml`)

**Automatically managed** by the application to store runtime state. This file should not be edited manually.

#### Window State
- **width**: Window width in pixels
- **height**: Window height in pixels
- **x**: Window X position
- **y**: Window Y position

Window state is automatically saved whenever you move or resize the window.

#### Font Size
- **font_size**: Font size in pixels (range: 8-96, default: 14)

Font size is automatically saved when adjusted via **⌘+** / **⌘-** keyboard shortcuts.

#### Terminal State
- Stored under the `[terminals]` table using 1-based grid coordinates in the key name: `terminal_<row>_<col>`
- Each value is the working directory of a terminal that was running when Architect exited
- Entries that fall outside the current grid size (after changing rows/columns) are ignored and removed on startup
- On launch, Architect automatically respawns those terminals in the saved directories when their grid cells exist
- Current cwd tracking is supported on macOS; other platforms skip saving terminal directories for now.

**Example:**
```
[terminals]
terminal_1_2 = "/Users/local/dev"
terminal_2_3 = "/Users/local/api"
```

### Font Loading

Fonts are loaded from macOS system directories, searched recursively:
1. `/System/Library/Fonts/` - System fonts (and subdirectories)
2. `/Library/Fonts/` - System-wide installed fonts (and subdirectories)
3. `~/Library/Fonts/` - User-installed fonts (and subdirectories)

**Supported font formats:**
- `.ttf` - TrueType fonts
- `.otf` - OpenType fonts
- `.ttc` - TrueType Collection (multiple variants in one file)

**Naming patterns searched (in order):**
- `{font_family}-{style}.{ext}` (e.g., `VictorMonoNerdFont-Bold.ttf`)
- `{font_family}{style}.{ext}` (e.g., `SFNSMonoBold.ttf`)
- `{font_family}.{ext}` for Regular style (e.g., `Monaco.ttf`)
- `{font_family}.ttc` - TTC file containing all variants

**Examples of supported fonts:**

| Font | Location | Type |
|------|----------|------|
| `SFNSMono` | `/System/Library/Fonts/SFNSMono.ttf` | Separate TTF files |
| `Menlo` | `/System/Library/Fonts/Menlo.ttc` | TTC with all variants |
| `Monaco` | `/System/Library/Fonts/Monaco.ttf` | Single TTF (no variants) |
| `VictorMonoNerdFont` | `/Library/Fonts/Nix Fonts/.../VictorMonoNerdFont-Regular.ttf` | Nerd Font in subdirectory |

**Fallback behavior:**

If a requested font isn't found, the app falls back to `SFNSMono` with a warning:
```
warning(font_paths): Font family 'MyFont' not found, falling back to SFNSMono
```

If style variants (Bold, Italic, BoldItalic) aren't found:
1. For TTC files: Uses the same TTC file for all variants (SDL_ttf loads correct variant)
2. For TTF/OTF: Falls back to default font's variant
3. Last resort: Uses Regular variant

**Example config.toml (user-editable):**
```toml
[font]
family = "VictorMonoNerdFont"

[theme]
background = "#1E1E2E"
foreground = "#CDD6F4"
accent = "#89B4FA"
selection = "#313244"

# Optional: custom ANSI palette colors (example: Catppuccin Mocha)
[theme.palette]
black = "#45475A"
red = "#F38BA8"
green = "#A6E3A1"
yellow = "#F9E2AF"
blue = "#89B4FA"
magenta = "#F5C2E7"
cyan = "#94E2D5"
white = "#BAC2DE"
bright_black = "#585B70"
bright_red = "#F38BA8"
bright_green = "#A6E3A1"
bright_yellow = "#F9E2AF"
bright_blue = "#89B4FA"
bright_magenta = "#F5C2E7"
bright_cyan = "#94E2D5"
bright_white = "#A6ADC8"

[grid]
rows = 3
cols = 4
font_scale = 1.2

[rendering]
vsync = true

[ui]
show_hotkey_feedback = true
enable_animations = true
```

**Example persistence.toml (automatically managed):**
```toml
[window]
width = 1920
height = 1080
x = 150
y = 100

font_size = 16
```

**Debugging font loading:**

Run the app and check logs to see which fonts were found:
```
info(font_paths): Found font: /Library/Fonts/.../VictorMonoNerdFont-Regular.ttf
info(font_paths): Found font: /Library/Fonts/.../VictorMonoNerdFont-Bold.ttf
info(font_paths): Found font: /Library/Fonts/.../VictorMonoNerdFont-Italic.ttf
info(font_paths): Found font: /Library/Fonts/.../VictorMonoNerdFont-BoldItalic.ttf
```

Or for TTC files:
```
info(font_paths): Found font: /System/Library/Fonts/Menlo.ttc
info(font_paths): Using TTC file for Bold variant: /System/Library/Fonts/Menlo.ttc
info(font_paths): Using TTC file for Italic variant: /System/Library/Fonts/Menlo.ttc
info(font_paths): Using TTC file for BoldItalic variant: /System/Library/Fonts/Menlo.ttc
```

To reset to defaults, delete the configuration files:
```bash
# Reset user configuration to defaults
rm ~/.config/architect/config.toml

# Reset runtime state (window position/size, font size)
rm ~/.config/architect/persistence.toml
```

The app will recreate `config.toml` with defaults on next launch. The `persistence.toml` will be recreated as you use the app.

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
- **Login shells**: Architect spawns shells with `-l`, so your login profiles (e.g., `/etc/zprofile`, `~/.zprofile`) run and provide system aliases and environment tweaks in every session.
- **Protocol**: Send a single-line JSON object to the socket:
  - `{"session":0,"state":"start"}` clears the highlight and marks the session as running.
  - `{"session":0,"state":"awaiting_approval"}` turns on a pulsing yellow border in the grid (request).
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

   This is the same shared script used by Codex and Gemini; it understands both plain state arguments and assistant JSON payloads.

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

1. Copy the shared notification script to your Codex config directory:
   ```bash
   cp architect_notify.py ~/.codex/architect_notify.py
   chmod +x ~/.codex/architect_notify.py
   ```

   The script now understands Codex notification payloads (`agent-turn-start`,
   `agent-turn-complete`, approval/permission prompts, etc.) as well as plain
   `start` / `awaiting_approval` / `done` arguments.

2. Add the `notify` setting to your `~/.codex/config.toml`:
   ```toml
   notify = ["python3", "/Users/your-username/.codex/architect_notify.py"]
   ```

   Replace the path with your username if needed.

3. Run Architect and start Codex in one of the terminal sessions. The grid cell will automatically highlight when Codex requests approval or completes a task. Unrecognized Codex events are ignored.

### Configuring Gemini CLI Hooks

To automatically send notifications when Gemini CLI requests approval or completes a task:

1. Copy the notification scripts from the repository:
   ```bash
   cp architect_notify.py ~/.gemini/architect_notify.py
   cp architect_hook_gemini.py ~/.gemini/architect_hook.py
   chmod +x ~/.gemini/architect_notify.py ~/.gemini/architect_hook.py
   ```

   **Note**: Gemini CLI hooks require special handling because they receive JSON via stdin and must output JSON to stdout. The `architect_hook.py` wrapper handles this protocol and delegates to the shared `architect_notify.py` script (the same one used for Claude and Codex).

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
- `src/font_paths.zig` - Font path resolution from macOS system font directories
- `src/config.zig` - Configuration loading (read-only user config) and persistence (runtime window/font state)
- `src/c.zig` - C library bindings for SDL3
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
- **Nix overlay and cache**: SDL3 is pinned to upstream 3.4.0 through `overlays/sdl3-3-4-0.nix`; binaries are served from the public `forketyfork` Cachix cache to avoid rebuilding locally or in CI.

## Architecture

### Terminal Scaling
Each terminal session is initialized with full-window dimensions (calculated from font metrics). In grid view, these full-sized terminals are scaled down to the current grid cell size, providing a "zoomed out" view of complete terminal sessions regardless of the configured rows/cols.

### Animation System
The application uses cubic ease-in-out interpolation to smoothly transition between grid and full-screen views over 300ms. Six view modes (Grid, Expanding, Full, Collapsing, PanningLeft, PanningRight) manage the animation state, including horizontal panning for terminal switching.

### Rendering Pipeline
1. Font glyphs are rendered to cached SDL textures
2. Terminal cells are iterated and glyphs drawn at scaled positions
3. Content is clipped to grid cell boundaries
4. Borders indicate focus state

## Implementation Status

✅ **Fully Implemented**:
- Configurable grid layout (defaults to 3×3) with per-cell terminal sessions
- PTY management and shell spawning
- Real-time terminal I/O
- SDL3 window and event loop with resizable window support
- Font rendering with SDL_ttf
- Click-to-expand interaction
- Smooth expand/collapse animations
- Keyboard input handling
- Full-window terminal scaling
- Dynamic terminal and PTY resizing on window resize
- Read-only user configuration (font family, theme, grid size, rendering settings)
- Automatic persistence of runtime state (window position/size, font size)
- Configuration editor via Cmd+, keyboard shortcut
- Font size adjustment via keyboard shortcuts (Cmd+Plus/Minus)
- Claude Code integration via Unix domain sockets
- Scrolling back through terminal history (mouse wheel) with a grid indicator when a pane is scrolled
- Text selection in full view with clipboard copy/paste (drag, ⌘C / ⌘V)
- Cmd+Click to open hyperlinks (OSC 8) in your default browser

## Known Limitations

The following features are not yet fully implemented:
- **Emoji coverage is macOS-only**: Apple Color Emoji fallback is used; other platforms may still show tofu or monochrome glyphs for emoji and complex ZWJ sequences.
- **Fonts must exist locally**: Architect relies on system-installed fonts; ensure your configured family is available on the host OS.
- **Limited configurability**: Keybindings are hardcoded

## License

MIT
