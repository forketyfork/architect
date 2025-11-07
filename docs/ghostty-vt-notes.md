# ghostty-vt Integration Notes

## Overview

`ghostty-vt` is a Zig module that provides a reusable terminal emulation layer extracted from the Ghostty terminal emulator. It includes escape sequence parsing, terminal state management, and screen state handling. The module is production-grade, used by thousands of Ghostty users, though the API itself is explicitly not stable and will change in the future.

## Module Purpose

The `ghostty-vt` library focuses solely on core terminal emulation:
- Terminal state management
- Screen state and scrollback buffer
- Escape sequence parsing (ANSI, CSI, OSC, DCS, APC)
- Character grid and cell management

It does **not** include:
- Rendering support
- PTY/shell process management
- Window management
- Input event handling (keyboard/mouse events from windowing systems)

## Zig Version Requirements

- Minimum Zig version: **0.15.2** (as of ghostty 1.3.0-dev)
- Reference implementation at: `/Users/sergei.petunin/dev/github/ghostty-org/ghostty`

## Integration Setup

### Build Configuration

Add ghostty as a dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .ghostty = .{
        .path = "../ghostty",  // or URL-based dependency
    },
},
```

In `build.zig`, wire the module:

```zig
if (b.lazyDependency("ghostty", .{
    // .simd = false,  // Disable for pure static builds (no libc)
})) |dep| {
    exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
}
```

### SIMD and Dependencies

The module has **two build modes**:

1. **SIMD disabled** (`.simd = false`):
   - Zero dependencies (not even libc)
   - Produces fully static standalone binaries
   - Significant performance penalty

2. **SIMD enabled** (default):
   - Requires libc and libcpp
   - Better performance
   - Recommended if your application already uses libc

## API Structure

### Core Types

Exposed via `@import("ghostty-vt")`:

- `Terminal` - Main terminal emulation structure
- `Screen` - Current screen state
- `Page` - Screen page/buffer
- `Cell` - Individual cell in the character grid
- `Parser` - Escape sequence parser
- `Stream` - Input stream processing
- `Cursor` - Cursor state and style

### Submodules

- `apc` - Application Program Command sequences
- `dcs` - Device Control String sequences
- `osc` - Operating System Command sequences
- `color` - Color handling
- `kitty` - Kitty-specific terminal features
- `modes` - Terminal mode management
- `input` - Key encoding and paste handling

### Input Handling

```zig
const input = @import("ghostty-vt").input;
// Key encoding
input.Key
input.KeyEvent
input.KeyMods
input.encodeKey
// Paste handling
input.PasteOptions
input.isSafePaste
input.encodePaste
```

## Initialization Flow

### Basic Terminal Setup

```zig
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

var terminal = try ghostty_vt.Terminal.init(alloc, .{
    .cols = 80,
    .rows = 24,
    .max_scrollback = 10000,  // Optional scrollback size
});
defer terminal.deinit(alloc);
```

### Terminal Operations

```zig
// Write text to terminal
try terminal.printString("Hello, World!\r\n");

// Process escape sequences
try terminal.print("\\x1b[1mBold text\\x1b[0m");

// Get screen contents
const str = try terminal.plainString(alloc);
defer alloc.free(str);

// Access screen state
const screen = terminal.getActiveScreen();
const cursor = screen.cursor;
```

## Integration Points

### What You Must Provide

1. **PTY Management**: Create and manage pseudo-terminal for shell processes
2. **Window/Surface**: Create and manage the application window
3. **Rendering Backend**: Implement text rendering (using font libraries)
4. **Input Forwarding**: Capture keyboard/mouse events and forward to VT
5. **Event Loop**: Poll for events, read PTY output, refresh display

### Typical Integration Flow

1. Initialize windowing backend (SDL2, GLFW, native APIs, etc.)
2. Create PTY and spawn shell process
3. Initialize `ghostty_vt.Terminal` with desired dimensions
4. In event loop:
   - Read shell output from PTY → `terminal.print(data)`
   - Capture keyboard input → encode with `input.encodeKey()` → write to PTY
   - Extract screen state → render to window surface
   - Handle resize events → `terminal.resize(cols, rows)`

## Reference Implementation

The example at `example/zig-vt` in the ghostty repository demonstrates basic usage:
- Path: `/Users/sergei.petunin/dev/github/ghostty-org/ghostty/example/zig-vt/`
- Minimal terminal initialization
- Writing text and extracting screen contents
- Proper memory management with allocators

## External Dependencies for Full Implementation

While `ghostty-vt` itself is zero or minimal dependency, a complete terminal application requires:

1. **PTY Library**:
   - POSIX: Use `std.posix` for `openpty`, `fork`, `exec`
   - Cross-platform: Consider libvterm or similar

2. **Windowing**:
   - SDL2
   - GLFW
   - Native APIs (Cocoa, Win32, Wayland/X11)

3. **Font Rendering**:
   - FreeType
   - HarfBuzz (for complex text shaping)
   - Fontconfig (for font discovery)

4. **Graphics**:
   - OpenGL/Vulkan/Metal
   - Software rendering (Cairo, Skia)

Ghostty itself uses a sophisticated rendering stack, but simpler approaches can work for prototypes.

## API Stability Warning

From the PR description:
> The API is extremely not stable and will definitely change in the future. The functionality/logic is very stable, because it's the same core logic used by Ghostty, but the API itself is not at all.

Plan for API changes when updating to newer ghostty versions. Pin to specific commits in production code.

## Build Flags

- `-Dsimd=true/false` - Enable/disable SIMD optimizations
- Default SIMD is **enabled**

## Testing

The module includes comprehensive tests:
```bash
zig build test-lib-vt
```

## Additional Resources

- PR #8840: https://github.com/ghostty-org/ghostty/pull/8840
- Example code: `example/zig-vt/` in ghostty repository
- Main library entrypoint: `src/lib_vt.zig`
- Core terminal logic: `src/terminal/Terminal.zig`
