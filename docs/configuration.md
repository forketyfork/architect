# Configuration

Architect stores its configuration in `~/.config/architect/` using two TOML files with distinct purposes:

| File | Purpose | Managed by |
|------|---------|------------|
| `config.toml` | User preferences (theme, font, grid size) | User (via `Cmd+,`) |
| `persistence.toml` | Runtime state (window position, font size, terminal cwds) | Application |

## config.toml

User-editable preferences file. Changes take effect on next launch. Open it quickly with `Cmd+,`.

If the file doesn't exist, Architect creates a commented template on first run.

### Font Configuration

```toml
[font]
family = "SFNSMono"  # Font family name (default: SFNSMono on macOS)
size = 14            # Base font size in points (default: 14)
```

The font family must be installed on your system. Common choices:
- `SFNSMono` (macOS system font, default)
- `MesloLGS NF` (Nerd Font with icons)
- `JetBrains Mono`
- `Fira Code`

### Grid Configuration

```toml
[grid]
font_scale = 1.0  # Font scale in grid view (0.5-3.0, default: 1.0)
```

The grid size is dynamic and adjusts automatically based on the number of terminals:
- Press `Cmd+N` to add a new terminal after the currently focused one — the grid expands to accommodate it
- Press `Cmd+W` to close a terminal — remaining terminals compact forward to fill gaps and the grid shrinks when possible; if it's the only terminal, it restarts in place (use `Cmd+Q` or the window close button to quit)
- When only one terminal is spawned, the view stays in full-screen mode
- Grid layout maintains `columns >= rows` (e.g., 1x1 → 2x1 → 2x2 → 3x2 → 3x3 → ...)
- Maximum grid size is 12×12 (144 terminals)

### Window Configuration

```toml
[window]
width = 1280    # Initial window width in pixels (default: 1280)
height = 720    # Initial window height in pixels (default: 720)
x = -1          # Initial X position (-1 = centered, default: -1)
y = -1          # Initial Y position (-1 = centered, default: -1)
```

Note: Runtime window position and size are saved to `persistence.toml` and take precedence over these values after the first launch.

### Theme Configuration

```toml
[theme]
background = "#0E1116"  # Terminal background color
foreground = "#CDD6E0"  # Default text color
selection = "#1B2230"   # Selection highlight color
accent = "#61AFEF"      # Accent color (focused borders, UI elements)
```

Colors are specified in hexadecimal format (`#RRGGBB` or `RRGGBB`).

#### Default Theme Colors

| Setting | Default | Description |
|---------|---------|-------------|
| `background` | `#0E1116` | Dark gray background |
| `foreground` | `#CDD6E0` | Light gray text |
| `selection` | `#1B2230` | Darker blue for selections |
| `accent` | `#61AFEF` | Blue accent for focus indicators |

### ANSI Palette

Customize the 16-color ANSI palette under `[theme.palette]`:

```toml
[theme.palette]
# Standard colors (0-7)
black = "#0E1116"
red = "#E06C75"
green = "#98C379"
yellow = "#D19A66"
blue = "#61AFEF"
magenta = "#C678DD"
cyan = "#56B6C2"
white = "#ABB2BF"

# Bright colors (8-15)
bright_black = "#5C6370"
bright_red = "#E06C75"
bright_green = "#98C379"
bright_yellow = "#E5C07B"
bright_blue = "#61AFEF"
bright_magenta = "#C678DD"
bright_cyan = "#56B6C2"
bright_white = "#CDD6E0"
```

Omitted colors fall back to the built-in One Dark-inspired palette.

### UI Configuration

```toml
[ui]
show_hotkey_feedback = true  # Show hotkey hints overlay (default: true)
enable_animations = true     # Enable expand/collapse animations (default: true)
```

### Rendering Configuration

```toml
[rendering]
vsync = true  # Enable vertical sync (default: true)
```

Disabling vsync may reduce input latency but can cause screen tearing.

### Metrics Configuration

```toml
[metrics]
enabled = false  # Enable metrics collection overlay (default: false)
```

When enabled, press `Cmd+Shift+M` to toggle the metrics overlay in the bottom-right corner. The overlay displays:
- **Frames**: Total rendered frame count
- **FPS**: Frames per second
- **Glyph cache**: Number of cached glyph textures
- **Glyph hit rate**: Cache hit percentage (hits / total accesses)
- **Glyph hits/s**: Glyph cache hits per second
- **Glyph misses/s**: Glyph cache misses per second
- **Glyph evictions/s**: Glyph cache evictions per second

Metrics collection has zero overhead when disabled (no allocations, null pointer checks compile away).

### Complete Example

```toml
# ~/.config/architect/config.toml

[font]
family = "JetBrains Mono"
size = 13

[grid]
font_scale = 0.9

[theme]
background = "#1E1E2E"
foreground = "#CDD6F4"
selection = "#45475A"
accent = "#89B4FA"

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

[ui]
show_hotkey_feedback = true
enable_animations = true

[rendering]
vsync = true

[metrics]
enabled = false
```

## persistence.toml

Auto-managed runtime state. Do not edit manually unless troubleshooting.

### Structure

```toml
font_size = 14
onboarding_shown = true

[window]
width = 1440
height = 900
x = 100
y = 50

terminals = [
  "/Users/me/projects/app",
  "/Users/me/projects/lib",
  "/Users/me",
]
```

### Fields

| Field | Description |
|-------|-------------|
| `font_size` | Current font size (adjusted with `Cmd++`/`Cmd+-`) |
| `onboarding_shown` | Whether the first-launch onboarding message has been displayed |
| `[window]` | Last window position and dimensions |
| `terminals` | Working directories for each terminal (ordered by session index) |

On launch, Architect restores terminals to their saved working directories. The grid automatically resizes to fit the number of restored terminals.

Note: Terminal cwd persistence is currently macOS-only.

Older `persistence.toml` files that used the `[terminals]` table are migrated automatically.

## Resetting Configuration

Delete the configuration files to reset to defaults:

```bash
rm ~/.config/architect/config.toml      # Reset preferences
rm ~/.config/architect/persistence.toml # Reset runtime state
```

Or remove the entire directory:

```bash
rm -rf ~/.config/architect
```
