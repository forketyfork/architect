# Architect

[![Build status](https://github.com/forketyfork/architect/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/architect/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)

![Architect Hero](docs/assets/architect-hero.png)

A terminal emulator that displays a configurable grid of interactive terminal sessions with smooth expand/collapse animations. Built on ghostty-vt for terminal emulation and SDL3 for rendering.

> [!WARNING]
> **This project is in the early stages of development. Use at your own risk.**
>
> The application is experimental and may have bugs, stability issues, or unexpected behavior.

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

### Build from Source

See `docs/development.md` for the full development setup. Quick start:

```bash
nix develop
just build
```

## Features

- Configurable grid of terminal sessions with smooth expand/collapse animations
- Full-window terminal rendering scaled down for grid view
- Keyboard navigation (⌘+Return to expand, ⌘1–⌘0 to switch, ⌘W to close, ⌘/ for shortcuts, ⌘T for worktrees)
- Scrollback with hover wheel/trackpad support and a grid indicator when scrolled
- Worktree picker for quick `cd` into git worktrees
- Persistent window and font size state; terminal cwd restore on macOS
- Cmd+Click opening for OSC 8 hyperlinks
- AI assistant status highlights (awaiting approval / done)
- Kitty keyboard protocol support for enhanced key handling

## Configuration

Architect stores configuration in `~/.config/architect/`:

- `config.toml`: read-only user preferences (edit via `⌘,`).
- `persistence.toml`: runtime state (window position/size, font size), managed automatically.

Common settings include font family, theme colors, and grid rows/cols. Remove the files to reset to the default values.

## Troubleshooting

- **App won’t open (Gatekeeper)**: run `xattr -dr com.apple.quarantine Architect.app` after extracting the release.
- **Font not found**: ensure the font is installed and set `font.family` in `config.toml`. The app falls back to `SFNSMono` on macOS.
- **Reset configuration**: delete `~/.config/architect/config.toml` and `~/.config/architect/persistence.toml`.
- **Known limitations**: emoji fallback is macOS-only; keybindings are currently fixed.

## Documentation

- `docs/architecture.md`: architecture overview and system boundaries.
- `docs/development.md`: build, test, release, and assistant hook setup.
- `CLAUDE.md`: agent guidelines for code assistants.

## License

MIT
