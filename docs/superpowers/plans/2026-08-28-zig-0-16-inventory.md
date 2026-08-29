# Zig 0.16.0 Migration Inventory

Recorded 2026-08-28 from the `spike/zig-0-16-inventory` branch.

## Environment

- Host: Linux AIR Cloud sandbox, x86_64, kernel 6.17.0-1017-aws
- Workspace: `/workspaces/architect`
- Current toolchain: `zig version` -> `0.15.2`
- Probe toolchain: `/tmp/zig016/zig version` -> `0.16.0`
- SDL headers: `$SDL3_INCLUDE_PATH` and `$SDL3_TTF_INCLUDE_PATH`, both supplied by the AIR Cloud startup environment
- `just`, ShellCheck, and Ruff were present. `pkg-config` was not installed, so SDL versions were not queried through pkg-config.
- The 0.16 probe used isolated caches: `.tmp/zig-cache-016` and `.tmp/zig-cache-016/local`.
- The plan's Nix-only `devShells.zig016` and `nix develop` steps were not run; this sandbox has no Nix.

## Dependency hashes

These hashes were printed by Zig 0.16.0's `zig fetch` for the exact URLs in the migration plan:

| Dependency | URL | Verified hash |
| --- | --- | --- |
| ghostty | `https://github.com/ghostty-org/ghostty/archive/76e568b475fe88f5506be33ad1a684f3c1eae85e.tar.gz` | `ghostty-1.3.2-dev-5UdBCzxaYAWrMeK4x7Kpz8hshXz6zm_SB1KdCFoLB6Lf` |
| libxev | `https://deps.files.ghostty.org/libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz` | `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` |
| toml | `https://github.com/sam701/zig-toml/archive/8685923e32e8b8a795eb2715684236975a70faed.tar.gz` | `toml-0.3.0-bV14BRmKAQAWR0FT0KUKFwVJTImaFhWjSe6HfSMtNZOH` |
| zwanzig | `https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.15.1.tar.gz` | `zwanzig-0.15.1-oiXZliOBGQA1fkoEDA6UxFdOv1ezRF5Jc9YY7uZnHjKe` |

## Risk verdicts

### Risk 1 — SDL3/SDL3_ttf `@cImport`: PASS

The standalone Zig 0.16.0 probe included `SDL3/SDL.h` and `SDL3_ttf/SDL_ttf.h`, touched representative constants/types/function pointers, linked both SDL libraries, and ran successfully. The compiler emitted no diagnostics. The executable printed:

```text
32 128 13 133482551094496
```

The first invocation without an explicit library search path failed only because this sandbox does not add its SDL prefix to Zig's default linker paths:

```text
error: unable to find dynamic system library 'SDL3' using strategy 'paths_first'. searched paths:
  /usr/local/lib/libSDL3.so
  /usr/local/lib/libSDL3.a
  /usr/lib/x86_64-linux-gnu/libSDL3.so
  /usr/lib/x86_64-linux-gnu/libSDL3.a
  /lib64/libSDL3.so
  /lib64/libSDL3.a
  /lib/libSDL3.so
  /lib/libSDL3.a
  /usr/lib64/libSDL3.so
  /usr/lib64/libSDL3.a
  /usr/lib/libSDL3.so
  /usr/lib/libSDL3.a
  /lib/x86_64-linux-gnu/libSDL3.so
  /lib/x86_64-linux-gnu/libSDL3.a
error: unable to find dynamic system library 'SDL3_ttf' using strategy 'paths_first'. searched paths:
  /usr/local/lib/libSDL3_ttf.so
  /usr/local/lib/libSDL3_ttf.a
  /usr/lib/x86_64-linux-gnu/libSDL3_ttf.so
  /usr/lib/x86_64-linux-gnu/libSDL3_ttf.a
  /lib64/libSDL3_ttf.so
  /lib64/libSDL3_ttf.a
  /lib/libSDL3_ttf.so
  /lib/libSDL3_ttf.a
  /usr/lib64/libSDL3_ttf.so
  /usr/lib64/libSDL3_ttf.a
  /usr/lib/libSDL3_ttf.so
  /usr/lib/libSDL3_ttf.a
  /lib/x86_64-linux-gnu/libSDL3_ttf.so
  /lib/x86_64-linux-gnu/libSDL3_ttf.a
```

Adding `-L"$SDL3_INCLUDE_PATH/../lib"` resolved that environment-only linker issue. There was no SDL header or Aro translate-c failure. **The migration was not stopped.**

### Risk 2 — ghostty `main` and `ghostty-vt`: PASS

With the four fresh hashes, Zig 0.16.0 resolved and compiled the ghostty snapshot and its generated dependencies, and the Architect command line included `-Mghostty-vt=.../src/lib_vt.zig`. The full build reached Architect's own source and ended with `38/43 steps succeeded (2 failed)`; there were no diagnostics about resolving `ghostty`, missing `ghostty-vt`, libxev, toml, or zwanzig.

### Risk 3 — dependency hash format: PASS

All four URLs were accepted by Zig 0.16.0 `zig fetch`, producing the hashes above. The unchanged Zwanzig v0.15.1 URL reproduced its existing hash.

### Risk 4 — zig-toml API: PASS for the exercised surface

The toml dependency resolved and compiled as part of the full build. A standalone Zig 0.16.0 compile of `src/config.zig` with the resolved toml module reached Architect's code and reported no toml parser/API diagnostic. It instead reported the expected unrelated standard-library changes:

```text
src/config.zig:326:64: error: missing struct field: items
    terminal_entries: std.ArrayListUnmanaged(TerminalEntry) = .{},
                                                              ~^~
src/config.zig:326:64: note: missing struct field: capacity
/tmp/zig016/lib/std/array_list.zig:576:12: note: struct declared here
    return struct {
           ^~~~~~
src/config.zig:1181:37: error: no field or member function named 'realpathAlloc' in 'Io.Dir'
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
                         ~~~~~~~~~~~^~~~~~~~~~~~~~
/tmp/zig016/lib/std/Io/Dir.zig:1:1: note: struct declared here
const Dir = @This();
^~~~~
src/config.zig:1273:37: error: no field or member function named 'realpathAlloc' in 'Io.Dir'
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
                         ~~~~~~~~~~~^~~~~~~~~~~~~~
/tmp/zig016/lib/std/Io/Dir.zig:1:1: note: struct declared here
const Dir = @This()
```

The parser's `Parser`/result API was not reached by a failure.

### Risk 5 — `std.Io.Writer` surface: PASS for the exercised surface

The repository has 12 existing `std.Io` sites. No `std.Io.Writer` diagnostic appeared in the untouched-source full build or in a libc-enabled standalone Zig 0.16.0 compile of `src/logging.zig`; the latter reached only `@Type` and filesystem diagnostics. The Writer call sites therefore need no inventory blocker, though they will be rechecked during the migration's normal build/test work.

## Untouched-source Zig 0.16.0 error inventory

After the build-script-only compatibility patch needed to execute `build.zig`, the source tree was restored untouched and `zig build` was run with Zig 0.16.0. It produced 3 source diagnostics, grouped as follows:

| Group | Count | Diagnostic |
| --- | ---: | --- |
| Logging callback type | 1 | `invalid builtin function: '@Type'` |
| Main entrypoint argument API | 1 | `root source file struct 'process' has no member named 'argsAlloc'` |
| MCP allocator API | 1 | `root source file struct 'heap' has no member named 'GeneralPurposeAllocator'` |
| **Total source diagnostics** | **3** | |

Verbatim compiler diagnostics:

```text
src/logging.zig:349:21: error: invalid builtin function: '@Type'
    comptime scope: @Type(.enum_literal),
                    ^~~~~~~~~~~~~~~~~~~~
src/main.zig:16:33: error: root source file struct 'process' has no member named 'argsAlloc'
    const argv = try std.process.argsAlloc(allocator);
                     ~~~~~~~~~~~^~~~~~~~~~
/tmp/zig016/lib/std/process.zig:1:1: note: struct declared here
const builtin = @import("builtin");
^
referenced by:
    callMain [inlined]: /tmp/zig016/lib/std/start.zig:698:59
    callMainWithArgs [inlined]: /tmp/zig016/lib/std/start.zig:638:20
    main: /tmp/zig016/lib/std/start.zig:663:28
    1 reference(s) hidden; use '-freference-trace=4' to see more
error: 2 compilation errors

src/mcp/main.zig:19:23: error: root source file struct 'heap' has no member named 'GeneralPurposeAllocator'
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
              ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
/tmp/zig016/lib/std/heap.zig:1:1: note: struct declared here
const std = @import("std.zig");
^
referenced by:
    callMain [inlined]: /tmp/zig016/lib/std/start.zig:737:30
    callMainWithArgs [inlined]: /tmp/zig016/lib/std/start.zig:638:20
    main: /tmp/zig016/lib/std/start.zig:663:28
    1 reference(s) hidden; use '-freference-trace=4' to see more
error: 1 compilation errors
```

The exact failed commands also showed all four resolved dependency modules and their source paths. No dependency-error line matched `ghostty`, `libxev`, `toml`, or `zwanzig`; the failures were exclusively in Architect source.

## macOS SDK workaround

Not testable in this Linux AIR Cloud sandbox; requires verification on a macOS host separately.

The 0.16 shell was intentionally not created here, and no conclusion is drawn about arm64e SDK linking or `scripts/setup-macos-sdk-workaround.sh`. Task 14 must verify whether the workaround remains necessary on macOS.

## Scope and cleanup

Temporary changes to `build.zig.zon`, `build.zig`, and source files were used only for probing and were discarded. The kept changes are this inventory and the Step 1 checklist updates in `2026-08-28-zig-0-16-migration.md`.
