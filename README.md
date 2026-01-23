# Architect

[![Build status](https://github.com/forketyfork/architect/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/architect/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)

![Architect Hero](docs/assets/architect-hero.png)

A terminal built for multi-agent AI coding workflows. Run Claude Code, Codex, or Gemini in parallel and see at a glance which agents need your attention. See more in [my article](https://forketyfork.github.io/blog/2026/01/21/running-4-ai-coding-agents-at-once-the-terminal-i-built-to-keep-up/).

Built on [ghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation and SDL3 for rendering.

## Why Architect?

Running multiple AI coding agents is the new normal. But existing terminals weren't built for this:

- **Agents sit idle** waiting for approval while you're focused elsewhere
- **Context switching** between tmux panes or tabs kills your flow
- **No visibility** into which agent needs attention right now

Architect solves this with a grid view that keeps all your agents visible, with **status-aware highlighting** that shows you instantly when an agent is awaiting approval or has completed its task.

> [!WARNING]
> **This project is in the early stages of development. Use at your own risk.**
>
> The application is experimental and may have bugs, stability issues, or unexpected behavior.



https://github.com/user-attachments/assets/a4e28a63-557a-44f3-9bae-47b2fd0a5dc6



## Features

### Agent-Focused
- **Status highlights** — agents glow when awaiting approval or done, so you never miss a prompt
- **Dynamic grid** — starts with a single terminal in full view; press ⌘N to add a terminal after the current one, and closing terminals compacts the grid forward
- **Grid view** — keep all agents visible simultaneously, expand any one to full screen
- **Worktree picker** (⌘T) — quickly `cd` into git worktrees for parallel agent work on separate branches

### Terminal Essentials
- Smooth animated transitions for grid expansion, contraction, and reflow (cells and borders move/resize together)
- Keyboard navigation: ⌘+Return to expand, ⌘1–⌘0 to switch grid slots, ⌘N to add, ⌘W to close a terminal (restarts if it's the only terminal), ⌘/ for shortcuts; quit with ⌘Q or the window close button
- Per-cell cwd bar in grid view with reserved space so terminal content stays visible
- Scrollback with trackpad/wheel support and grid indicator when scrolled
- OSC 8 hyperlink support (Cmd+Click to open)
- Kitty keyboard protocol for enhanced key handling
- Persistent window state and font size across sessions

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

* The archive contains `Architect.app`. You can launch it with `open Architect.app` or run `./Architect.app/Contents/MacOS/architect` from the terminal. Keep the bundle contents intact.
* Not sure which architecture? Run `uname -m` - if it shows `arm64`, use the ARM64 version; if it shows `x86_64`, use the Intel version.

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

See [`docs/development.md`](docs/development.md) for the full development setup. Quick start:
```bash
nix develop
just build
```

## Configuration

Architect stores configuration in `~/.config/architect/`:

* `config.toml`: read-only user preferences (edit via `⌘,`).
* `persistence.toml`: runtime state (window position/size, font size, terminal cwds), managed automatically.

Common settings include font family, theme colors, and grid font scale. The grid size is dynamic and adapts to the number of terminals. Remove the files to reset to the default values.

## Troubleshooting

* **App won't open (Gatekeeper)**: run `xattr -dr com.apple.quarantine Architect.app` after extracting the release.
* **Font not found**: ensure the font is installed and set `font.family` in `config.toml`. The app falls back to `SFNSMono` on macOS.
* **Reset configuration**: delete `~/.config/architect/config.toml` and `~/.config/architect/persistence.toml`.
* **Crash after closing a terminal**: update to the latest build; older builds could crash after terminal close events on macOS.
* **Known limitations**: emoji fallback is macOS-only; keybindings are currently fixed.

## Documentation

* [`docs/ai-integration.md`](docs/ai-integration.md): set up Claude Code, Codex, and Gemini CLI hooks for status notifications.
* [`docs/architecture.md`](docs/architecture.md): architecture overview and system boundaries.
* [`docs/configuration.md`](docs/configuration.md): detailed configuration reference for `config.toml` and `persistence.toml`.
* [`docs/development.md`](docs/development.md): build, test, and release process.
* [`CLAUDE.md`](CLAUDE.md): agent guidelines for code assistants.

## Related Tools

Architect is part of a suite of tools I'm building for AI-assisted development:

- [**Stepcat**](https://github.com/forketyfork/stepcat) — Multi-step agent orchestration with Claude Code and Codex
- [**Marx**](https://github.com/forketyfork/marx) — Run Claude, Codex, and Gemini in parallel for PR code review
- [**Claude Nein**](https://github.com/forketyfork/claude-nein) — macOS menu bar app to monitor Claude Code spending

## License

MIT
