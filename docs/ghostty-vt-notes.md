# ghostty-vt Integration Notes

## Overview

`ghostty-vt` is a Zig module extracted from Ghostty that provides production-grade terminal emulation capabilities. It focuses on core terminal emulation, terminal state, and screen state management without rendering or input handling, making it suitable for embedding in custom terminal applications.

**Key characteristics:**
- Zero dependencies when SIMD is disabled (produces fully static binaries)
- Only requires libc when SIMD is enabled
- API is explicitly unstable and will change in future versions
- Functionality is stable (used by thousands in production Ghostty)
- Introduced in PR #8840 (merged)

## Build Requirements

### Zig Version
- Minimum Zig version: **0.15.1** (example code)
- Ghostty main requires: **0.15.2**
- Use the version specified in the consuming project's `build.zig.zon`

### Dependencies

#### Core Module
- **ghostty-vt**: Zero dependencies without SIMD
- **With SIMD enabled** (default): Requires libc and libcpp
- **Unicode tables**: Always required (provided by Ghostty)

#### Optional Features
- **SIMD support**: Controlled via `-Dsimd` build flag (default: on)
  - Significant performance benefit
  - Adds libc/libcpp dependency
  - Should be kept enabled unless pure static build is required

- **Regex support**: Currently not exposed in ghostty-vt module
  - Ghostty is transitioning away from Oniguruma
  - May be added as optional feature in future

## Integration Patterns

### Adding as Dependency

In `build.zig.zon` (URL + hash; tarball fetched automatically):

```zig
.dependencies = .{
    .ghostty = .{
        .url = "https://github.com/ghostty-org/ghostty/archive/f705b9f46a4083d8053cfa254898c164af46ff34.tar.gz",
        .hash = "122022d77cfd6d901de978a2667797a18d82f7ce2fd6c40d4028d6db603499dc9679",
    },
},
```

### Build Configuration

In `build.zig`:

```zig
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// Use lazy dependency to avoid downloading unless needed
if (b.lazyDependency("ghostty", .{
    // Disable SIMD for pure static builds (performance penalty)
    // .simd = false,
})) |dep| {
    exe_mod.addImport(
        "ghostty-vt",
        dep.module("ghostty-vt"),
    );
}
```

## API Overview

### Terminal Initialization

Basic initialization flow:

```zig
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

var t: ghostty_vt.Terminal = try .init(alloc, .{
    .cols = 80,
    .rows = 24,
});
defer t.deinit(alloc);
```

### Key Types and Modules

#### Core Terminal Types
- `Terminal`: Main terminal emulator instance
- `Screen`: Terminal screen state
- `Parser`: Escape sequence parser
- `Page`: Screen page management
- `Cell`: Individual character cell with styling

#### Color and Styling
- `color`: Color handling and conversion
- `Style`: Text styling attributes
- `Attribute`: SGR (Select Graphic Rendition) attributes
- `x11_color`: X11 color name resolution

#### Terminal State
- `modes`: Terminal mode management (ModePacked, Mode)
- `Cursor`: Cursor state and positioning
- `CursorStyle`: Visual cursor styles
- `Point`, `Coordinate`: Screen position types
- `size`: Screen size management

#### Escape Sequences
- `CSI`: Control Sequence Introducer
- `DCS`: Device Control String
- `osc`: Operating System Command
- `apc`: Application Program Command

#### Input Handling
- `input.Key`: Key representation
- `input.KeyEvent`: Keyboard events
- `input.KeyMods`: Modifier keys
- `input.encodeKey`: Convert key events to terminal sequences
- `input.encodePaste`: Handle paste data encoding
- `input.isSafePaste`: Validate paste safety

#### Advanced Features
- `Selection`: Text selection management
- `search`: Terminal content search
- `kitty`: Kitty terminal protocol extensions
- `formatter`: Terminal output formatting
- `StringMap`: String mapping utilities

### Usage Patterns

#### Simple Text Output

```zig
try t.printString("Hello, World!");

const str = try t.plainString(alloc);
defer alloc.free(str);
std.debug.print("{s}\n", .{str});
```

#### Stream-Based Parsing

For parsing escape sequences:

```zig
var stream = t.vtStream();
defer stream.deinit();

try stream.nextSlice("Hello, World!\r\n");
try stream.nextSlice("\x1b[1;32mGreen Text\x1b[0m\r\n");
try stream.nextSlice("\x1b[1;1HTop-left corner\r\n");

const str = try t.plainString(alloc);
defer alloc.free(str);
```

### PTY Integration

`ghostty-vt` does **not** provide PTY management. For shell integration:

- PTY creation and management must be handled separately
- Use system PTY APIs (e.g., `posix_openpt`, `grantpt`, `unlockpt` on Unix)
- Wire PTY output to `Terminal` via `vtStream().nextSlice()`
- Wire keyboard input through `input.encodeKey()` then to PTY input
- Handle SIGWINCH signals to update terminal size

Ghostty's main codebase provides reference implementations:
- `src/pty.zig`: PTY lifecycle management
- `src/termio/Termio.zig`: Terminal I/O coordination
- Example usage in `src/main_ghostty.zig`

### Rendering Integration

`ghostty-vt` does **not** provide rendering. For display:

- Terminal maintains grid state internally via `Screen` and `Page`
- Access cell contents via `Page` APIs
- Extract styling info from `Cell` (colors, attributes)
- Choose rendering backend independently (SDL2, GLFW, OpenGL, etc.)
- Render loop: poll PTY → update terminal → extract grid → render

Rendering considerations:
- Font rendering: Use FreeType, HarfBuzz, or similar
- Grid layout: Calculate cell positions based on font metrics
- Color handling: Convert terminal colors to RGB via `color` module
- Cursor rendering: Query cursor position and style from `Screen`

## Memory Management

- All Terminal operations require an allocator
- Use `std.heap.DebugAllocator` for development (leak detection)
- Consider `std.heap.ArenaAllocator` for short-lived terminals
- Call `Terminal.deinit(alloc)` to free resources
- Stream objects also require `deinit()`

## Testing

Run upstream tests (requires cloning ghostty separately):

```bash
git clone https://github.com/ghostty-org/ghostty.git
cd ghostty
zig build test-lib-vt
```

Test with/without SIMD:

```bash
zig build test-lib-vt -Dsimd=false
zig build test-lib-vt -Dsimd=true
```

## Example Code Locations

In the ghostty repository (clone separately):
- `example/zig-vt/`: Basic terminal creation and text output
- `example/zig-vt-stream/`: Escape sequence parsing via streams
- `example/c-vt/`: C API examples (for future C bindings)
- `src/lib_vt.zig`: Public API definition
- `src/terminal/main.zig`: Core terminal implementation

## Limitations and Future Work

Current limitations:
- API is unstable and will change
- No C API yet (coming soon)
- Regex support not exposed
- No built-in PTY management
- No built-in rendering support

Planned improvements (from PR #8840):
- Stable Zig API
- C API with language bindings
- Better documentation
- Clarified regex engine story
- Potential for sub-libraries (libghostty-input, libghostty-render, etc.)

## Platform Support

Supported platforms:
- Linux (fully supported)
- macOS (fully supported)
- WebAssembly (special build mode available)
- Other POSIX systems (likely work, may need adjustments)

## Performance Considerations

- SIMD provides significant performance improvements
- Disable SIMD only if:
  - Pure static binary is required
  - Target platform lacks libc
  - Binary size is critical constraint

- Memory usage scales with:
  - Terminal size (cols × rows)
  - Scrollback buffer depth
  - Number of Terminal instances

## Summary

**For the Terminal Wall project:**

1. **Setup**: Add ghostty as path dependency in `build.zig.zon`
2. **Build**: Import ghostty-vt module via `lazyDependency()`
3. **Usage**: Create Terminal instances with desired geometry
4. **PTY**: Integrate system PTY APIs separately (see `src/pty.zig` reference)
5. **Rendering**: Choose windowing backend (SDL2/GLFW) and implement grid rendering
6. **Input**: Use `input.encodeKey()` for keyboard events to PTY

The module provides rock-solid terminal emulation but requires separate PTY and rendering layers, which gives flexibility for the 3×3 grid layout and animation requirements.
