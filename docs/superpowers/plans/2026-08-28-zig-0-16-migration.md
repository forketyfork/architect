# Task: Zig 0.16.0 Migration

Migrate Architect from Zig 0.15.2 to Zig 0.16.0 through a staged dependency, API, toolchain, and documentation update.

**Goal:** Move Architect from Zig 0.15.2 to Zig 0.16.0 as a hard cutover, landing every 0.15.2-compatible piece on `main` first so the irreversible toolchain flip is a small, reviewable change.

**Architecture:** Zig 0.16 requires an `std.Io` instance at every filesystem, clock, sleep, mutex, and subprocess call site. `io` is threaded explicitly, as a struct field beside the existing `allocator` field or a parameter beside the existing `allocator` parameter — never via a global. The one exception is environment variables, which `std.Io` cannot supply: `src/env.zig` holds the process `Environ`, preserving the global-accessor semantics `std.posix.getenv` already had. Two further shared-utility modules, `src/clock.zig` and `src/proc.zig`, collapse the scattered timestamp and subprocess sites so the flip diff stays small.

**Tech Stack:** Zig 0.16.0, SDL3 + SDL3_ttf via `@cImport`, ghostty-vt, libxev, zig-toml, zwanzig (lint), Nix flakes (mitchellh/zig-overlay), `just`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-28-zig-0-16-migration-design.md`

**Execution phases:**
- **Phase 0 — Risk verification:** Task 1 is a throwaway Zig 0.16.0 spike that records dependency, translate-c, compiler-error, and SDK findings.
- **Phase 1 — Prep on Zig 0.15.2:** Tasks 2–5 are independently mergeable preparation PRs that keep the current toolchain green.
- **Phase 2 — The flip:** Tasks 6–15 run on one Zig 0.16.0 branch and PR; Tasks 6–12 remove migration error classes, Task 13 reaches the green gate, and Tasks 14–15 finish platform and documentation validation.

## Global Constraints

- Target toolchain is **exactly Zig 0.16.0**. `flake.nix` devShell pins `zig.packages.${system}."0.16.0"`; `build.zig.zon` sets `.minimum_zig_version = "0.16.0"`.
- **No behavior change anywhere.** Any observable difference is a migration defect, not an accepted trade-off.
- Phase 1 tasks must compile, test, and lint green under **Zig 0.15.2** (the toolchain currently in `flake.nix`). Phase 2 tasks run under 0.16.0.
- `zig build test` must be run **unpiped** in the call whose exit code decides success. Piping masks failures. To capture output for inspection, run it twice: once piped to a file for reading, once unpiped for the verdict.
- Error handling per `CLAUDE.md`: never `catch {}` or `catch unreachable`. Every error is propagated or logged. Lock acquisition uses `lockUncancelable`/`waitUncancelable` so no unrecoverable error paths are introduced.
- `std.ArrayList` usage stays exactly as-is: init with `.empty` (or `initCapacity`), allocator passed to each method. In 0.16 `std.ArrayList` *is* the unmanaged list; do not "migrate" it.
- Any new file that declares tests must be added to the `test { _ = @import(...); }` block in `src/main.zig`. `scripts/check-test-registry.sh` (part of `just lint`) enforces this.
- Run `zig fmt src/` before every commit.
- Conventional commit messages. Branch from an up-to-date `main`.
- Do not add fallbacks. One explicit, well-diagnosed failure beats silent recovery.

## PR grouping

| PR | Tasks | Toolchain |
| --- | --- | --- |
| (none — throwaway branch, discarded) | 1 | 0.16.0 |
| Prep 1 | 2 | 0.15.2 |
| Prep 2 | 3 | 0.15.2 |
| Prep 3 | 4, 5 | 0.15.2 |
| Flip | 6 – 15 | 0.16.0 |

Tasks 6 through 15 live on **one branch and one PR**. Architect cannot build on both toolchains at once, so intermediate commits within the flip will not compile. Each flip task therefore gates on *the disappearance of a specific compiler-error class* rather than on a green build; the full green gate is Task 13.

## File structure

**Created:**

| File | Responsibility |
| --- | --- |
| `src/env.zig` | Process environment access. Holds the `Environ` set once at startup; `init` / `get`. The only sanctioned module-level accessor in this migration. |
| `src/clock.zig` | Wall-clock and monotonic time reads. Wraps the 13 former `std.time.*Timestamp` sites. |
| `src/proc.zig` | Subprocess execution. Wraps the "run a command, collect stdout/stderr, inspect term" pattern shared by 4 of the 7 former `std.process.Child` sites. |

**Modified — 21 source files + build config.** The 20 files carrying 0.16-breaking API sites, plus `src/ui/components/recent_folders_overlay.zig`, which needs only the `env.get` rename from Task 3 and no `io`:

`build.zig`, `build.zig.zon`, `flake.nix`, `src/main.zig`, `src/mcp/main.zig`, `src/app/control.zig`, `src/app/layout.zig`, `src/app/runtime.zig`, `src/app/worktree.zig`, `src/config.zig`, `src/font_paths.zig`, `src/logging.zig`, `src/os/open.zig`, `src/session/notify.zig`, `src/session/pty_reader.zig`, `src/session/state.zig`, `src/shell.zig`, `src/ui/components/diff_overlay.zig`, `src/ui/components/pr_dropdown.zig`, `src/ui/components/pr_dropdown_fetch.zig`, `src/ui/components/pr_dropdown_repo.zig`, `src/ui/components/recent_folders_overlay.zig`, `src/ui/components/story_overlay.zig`, `src/ui/components/worktree_overlay.zig`.

**Explicitly not modified:** `src/ui/root.zig` and `src/ui/components/cwd_bar.zig`. Neither performs IO, clock, subprocess, or synchronization work, so neither needs `io`. Adding a field to `UiRoot` "for convenience" would be a speculative API change.

**Docs modified:** `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/development.md`, `README.md` (conditional), `docs/perf-debugging.md` (conditional).

---

## Step 1: Prove the 0.16 dependency graph and SDL3 translate-c (throwaway spike)

Nothing in the prep work is worth writing if the 0.16 dependency graph cannot resolve or if `@cImport` on SDL3's headers breaks under 0.16's Aro-based translate-c. This task produces **facts and hashes**, not code. Every source patch made here is discarded.

**Files:**
- Create: `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md` (the only artifact kept)
- Throwaway (discarded at end): `flake.nix`, `build.zig.zon`, any source patch

**Interfaces:**
- Consumes: nothing
- Produces: the four verified `build.zig.zon` dependency hashes used verbatim by Task 6; a decision on the macOS SDK workaround used by Task 14; a full `zig build` error inventory that later flip tasks check their progress against

- [x] **Step 1: Create a throwaway branch**

```bash
git checkout main && git pull origin main
git checkout -b spike/zig-0-16-inventory
```

- [ ] **Step 2: Add a 0.16.0 dev shell alongside the existing one**

Do not change `devShells.default` — the point is to leave 0.15.2 working. In `flake.nix`, after the `devShells.default = pkgs.mkShell { ... };` block, add a sibling shell that is a copy with the Zig version swapped and the macOS SDK workaround omitted:

```nix
        devShells.zig016 = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            just
            ruff
            shellcheck
            zig.packages.${system}."0.16.0"
            pkg-config
            gw
          ];

          buildInputs =
            [
              sdl3.dev
              sdl3_ttf
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.gawk
              pkgs.gnused
            ];

          shellHook = ''
            export PKG_CONFIG_PATH="${sdl3}/lib/pkgconfig:${sdl3_ttf}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export SDL3_INCLUDE_PATH="${sdl3.dev}/include"
            export SDL3_TTF_INCLUDE_PATH="${sdl3_ttf}/include"
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.tmp/zig-cache-016"
            export ZIG_LOCAL_CACHE_DIR="$PWD/.tmp/zig-cache-016/local"
          ''
          + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            unset SDKROOT
            unset DEVELOPER_DIR
            export PATH=$(echo "$PATH" | ${pkgs.gawk}/bin/awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | ${pkgs.gnused}/bin/sed 's/:$//')
          '');
        };
```

The cache redirect into `.tmp/` matters: the default cache locations may be read-only under the sandbox.

- [ ] **Step 3: Confirm the shell resolves**

Run: `nix develop .#zig016 --command zig version`
Expected: `0.16.0`

- [x] **Step 4: Regenerate all four dependency hashes**

Edit `build.zig.zon` to set `.minimum_zig_version = "0.16.0"` and replace the four dependency URLs, then let `zig fetch` compute each hash. This is the step that answers Risk 3 (whether 0.16 accepts 0.15-era hash strings at all).

```bash
nix develop .#zig016 --command bash -c '
  set -euo pipefail
  for url in \
    "https://github.com/ghostty-org/ghostty/archive/76e568b475fe88f5506be33ad1a684f3c1eae85e.tar.gz" \
    "https://deps.files.ghostty.org/libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz" \
    "https://github.com/sam701/zig-toml/archive/8685923e32e8b8a795eb2715684236975a70faed.tar.gz" \
    "https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.15.1.tar.gz" \
  ; do
    echo "== $url"
    zig fetch "$url"
  done
'
```

Record each printed hash in the inventory doc. Expected: four hash strings of the form `<name>-<version>-<base64>`.

- [x] **Step 5: Answer Risk 1 — does `@cImport` on SDL3 still work?**

This is the highest-value question in the spike, and `src/c.zig` re-exports 224 symbols that depend on it. Isolate it from every other error class with a standalone probe rather than a full build:

```bash
mkdir -p .tmp/cimport-probe
cat > .tmp/cimport-probe/probe.zig <<'EOF'
const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

pub fn main() void {
    // Touch a representative spread: init flags, an opaque handle type, a
    // struct, an enum constant, a function pointer, and a TTF entry point.
    std.debug.print("{d} {d} {d} {d}\n", .{
        @as(u64, c.SDL_INIT_VIDEO),
        @sizeOf(c.SDL_Event),
        @as(c_int, c.SDLK_RETURN),
        @intFromPtr(&c.TTF_OpenFont),
    });
}
EOF
nix develop .#zig016 --command bash -c '
  zig build-exe .tmp/cimport-probe/probe.zig -lc -lSDL3 -lSDL3_ttf \
    -I"$SDL3_INCLUDE_PATH" -I"$SDL3_TTF_INCLUDE_PATH" \
    -femit-bin=.tmp/cimport-probe/probe 2>&1 | tee .tmp/cimport-probe/result.txt
'
```

Expected on success: no output from the compiler, and `.tmp/cimport-probe/probe` exists.
If it fails: record every diagnostic verbatim in the inventory doc. **Stop the whole migration here and report to the user** — a translate-c failure on SDL3 headers changes what this migration is, and the plan from Task 2 onward assumes `src/c.zig` keeps its shape.

- [x] **Step 6: Answer Risk 2 — does ghostty `main` resolve and expose `ghostty-vt`?**

```bash
nix develop .#zig016 --command bash -c 'zig build 2>&1 | tee .tmp/zig016-build-errors.txt' || true
grep -n "ghostty" .tmp/zig016-build-errors.txt || echo "no ghostty errors"
```

Expected: errors in Architect's own source (`build.zig` first, since `std.fs.openDirAbsolute` and `std.posix.getenv` are gone), but **no** error about resolving the `ghostty` dependency or about `dep.module("ghostty-vt")` being absent. Any ghostty-resolution or ghostty-vt-API error is a blocker: record it and report to the user.

- [x] **Step 7: Answer Risk 4 — does zig-toml's `zig-0.16` branch match Architect's usage?**

Once `build.zig` errors are patched enough for the compiler to reach `src/config.zig`, check the toml diagnostics specifically:

```bash
grep -n "toml" .tmp/zig016-build-errors.txt || echo "no toml errors"
```

Record any parser API drift. Pay particular attention to whether `Parser`, `parseString`/`parseFile`, and the result type's `deinit` keep their shapes, since `CLAUDE.md` records two live hazards there: parser-owned maps must not outlive `result.deinit()`, and persisted map keys *and* values must both be duplicated.

- [x] **Step 8: Answer Risk 5 and produce the full error inventory**

Patch `build.zig` minimally (throwaway) until the compiler gets past it, then capture the complete error set for `src/`:

```bash
nix develop .#zig016 --command bash -c 'zig build 2>&1 | tee .tmp/zig016-build-errors.txt' || true
grep -c "error:" .tmp/zig016-build-errors.txt
grep -o "error: [^\n]*" .tmp/zig016-build-errors.txt | sort | uniq -c | sort -rn
```

Record the total count and the grouped breakdown. Note any `std.Io.Writer` diagnostics (Risk 5) at the 12 existing `std.Io.*` sites.

- [x] **Step 9: Answer the SDK-workaround question**

The `.#zig016` shell above deliberately omits `scripts/setup-macos-sdk-workaround.sh`. If Steps 5–8 linked successfully without it, record "0.16 linker does not need the arm64e SDK workaround on this host". If linking failed with arm64e/SDK diagnostics, record the diagnostics and the conclusion that the workaround must stay. Task 14 consumes this.

- [x] **Step 10: Write the inventory doc**

Create `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md` containing: the environment used; the four verified hashes; the Risk 1–5 verdicts with verbatim diagnostics; the grouped error inventory from Step 8; and the SDK-workaround conclusion.

- [x] **Step 11: Discard every source patch, keep only the inventory**

```bash
git stash list
git checkout -- flake.nix build.zig.zon build.zig src/ 2>/dev/null || true
git status --short
git add docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md
git commit -m "docs: record Zig 0.16.0 breakage inventory from spike"
```

Expected: `git status --short` shows only the inventory doc. `flake.nix`, `build.zig.zon`, `build.zig`, and `src/` are all clean.

- [x] **Step 12: Verify 0.15.2 is still green on this branch**

Run: `nix develop --command just build`
Run: `nix develop --command just test`
Run: `nix develop --command just lint`
Expected: all pass. The spike must leave `main`'s toolchain untouched.

- [x] **Step 13: Open the inventory PR**

Use the `managing-github` skill. This PR contains one new doc and no code.

---

Tasks 2–5 compile, test, and lint under the **current** toolchain. Each task is a mergeable PR against `main`.

## Step 2: Move linking onto the modules in `build.zig`

Zig 0.16 removes `linkSystemLibrary`, `linkLibC`, `linkFramework`, `addIncludePath`, `addLibraryPath`, and `addFrameworkPath` from `std.Build.Step.Compile`; they live only on `std.Build.Module`. Both spellings exist in 0.15.2, so this is a pure refactor today.

**Files:**
- Modify: `build.zig:70-100` (link and include configuration), `build.zig:120` (`mcp_unit_tests.linkLibC()`), `build.zig:151`, `build.zig:178` (`std.posix.getenv`)

**Interfaces:**
- Consumes: nothing
- Produces: `exe_mod` and `mcp_mod` carry all linkage; no `Compile`-level link calls remain

- [ ] **Step 1: Set `link_libc` at module creation**

In `build.zig`, add `.link_libc = true` to both `b.createModule` calls:

```zig
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
```

- [ ] **Step 2: Move the system libraries and frameworks onto `exe_mod`**

Replace the block that currently starts at `exe.linkSystemLibrary("SDL3");` with the module-based spelling. Note `Module.linkSystemLibrary` and `Module.linkFramework` both take an options struct, so pass `.{}`. `headerpad_max_install_names` stays on the `Compile` steps — it is still a `Compile` field in 0.16.

```zig
    exe_mod.linkSystemLibrary("SDL3", .{});
    exe_mod.linkSystemLibrary("SDL3_ttf", .{});

    if (target.result.os.tag == .macos) {
        exe.headerpad_max_install_names = true;
        mcp_exe.headerpad_max_install_names = true;

        exe_mod.linkSystemLibrary("proc", .{});
        exe_mod.linkFramework("Carbon", .{});
        exe_mod.linkFramework("CoreFoundation", .{});
        exe_mod.linkFramework("AppKit", .{});

        if (findSdkRoot(b)) |sdk_root| {
            const framework_path = b.fmt("{s}/System/Library/Frameworks", .{sdk_root});
            exe_mod.addFrameworkPath(.{ .cwd_relative = framework_path });
        }
    }
```

The two `exe.linkLibC();` and `mcp_exe.linkLibC();` lines are deleted — Step 1 replaced them.

- [ ] **Step 3: Move the SDL include and library paths onto `exe_mod`, and read env through the build graph**

`std.posix.getenv` is gone in 0.16; `std.Build.Graph` carries an env map in both versions (`env_map` in 0.15.2, renamed to `environ_map` in 0.16 — Task 6 does the rename). Use the 0.15.2 spelling now:

```zig
    if (b.graph.env_map.get("SDL3_INCLUDE_PATH")) |sdl3_include| {
        exe_mod.addIncludePath(.{ .cwd_relative = sdl3_include });
        const lib_path = b.fmt("{s}/../lib", .{sdl3_include});
        exe_mod.addLibraryPath(.{ .cwd_relative = lib_path });
    }
    if (b.graph.env_map.get("SDL3_TTF_INCLUDE_PATH")) |sdl3_ttf_include| {
        exe_mod.addIncludePath(.{ .cwd_relative = sdl3_ttf_include });
        const ttf_lib_path = b.fmt("{s}/../lib", .{sdl3_ttf_include});
        exe_mod.addLibraryPath(.{ .cwd_relative = ttf_lib_path });
    }
```

- [ ] **Step 4: Convert the two remaining `std.posix.getenv` calls in the SDK helpers**

`findSdkRoot` and `findDeveloperDirSdkRoot` both already take `b`, so they can reach the graph:

```zig
fn findSdkRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.env_map.get("SDKROOT")) |sdk_root| {
        return sdk_root;
    }
```

```zig
fn findDeveloperDirSdkRoot(b: *std.Build) ?[]const u8 {
    const developer_dir = b.graph.env_map.get("DEVELOPER_DIR") orelse return null;
```

- [ ] **Step 5: Drop the now-redundant test-step libc call**

`mcp_unit_tests` is built from `mcp_mod`, which Step 1 gave `link_libc = true`, so delete the line:

```zig
    const mcp_unit_tests = b.addTest(.{
        .root_module = mcp_mod,
    });
```

(the `mcp_unit_tests.linkLibC();` line that followed is removed)

- [ ] **Step 6: Verify no `Compile`-level link calls survive**

Run: `grep -nE '\b(exe|mcp_exe|exe_unit_tests|mcp_unit_tests)\.(linkSystemLibrary|linkLibC|linkFramework|addIncludePath|addLibraryPath|addFrameworkPath)\b' build.zig`
Expected: no output.

Run: `grep -n 'std\.posix\.getenv' build.zig`
Expected: no output.

- [ ] **Step 7: Verify the build still links SDL3 correctly**

A build-script refactor has no unit test; its validation is that the binary still links what it needs. Run the build and inspect the result:

Run: `nix develop --command zig build`
Expected: exit 0.

Run (macOS): `otool -L zig-out/bin/architect | grep -E 'SDL3|SDL3_ttf'`
Expected: both `libSDL3` and `libSDL3_ttf` appear. If either is missing, Step 2 dropped a library.

Run (macOS): `otool -L zig-out/bin/architect | grep -cE 'Carbon|CoreFoundation|AppKit'`
Expected: `3`.

- [ ] **Step 8: Verify tests and lint**

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

Run: `nix develop --command just lint`
Expected: exit 0.

- [ ] **Step 9: Run the app to confirm it still starts**

Run: `nix develop --command zig build run`
Expected: the window opens with a working terminal grid. Close it. If the SDL include paths regressed, the build would have failed at Step 7, but a runtime dynamic-link failure would only show here.

- [ ] **Step 10: Format and commit**

```bash
nix develop --command zig fmt src/
git add build.zig
git commit -m "build: move linking onto root modules

Zig 0.16 removes the link and include methods from std.Build.Step.Compile
and keeps them only on std.Build.Module. Both spellings work in 0.15.2, so
this lands ahead of the toolchain bump. Environment reads move to
b.graph.env_map because std.posix.getenv is also removed in 0.16."
```

- [ ] **Step 11: Open the PR**

Use the `managing-github` skill.

---

## Step 3: Introduce `src/env.zig` and drop `GeneralPurposeAllocator`

Zig 0.16 removes `std.posix.getenv` and `std.heap.GeneralPurposeAllocator`. `std.Io` cannot supply environment access (`lib/std/Io.zig` has no `Environ` surface at all), so environment reads get a dedicated module rather than a second threaded context.

**Files:**
- Create: `src/env.zig`
- Modify: `src/main.zig:36-84` (test registry), `src/app/runtime.zig:1410`, `src/mcp/main.zig:19`, and all 23 `getenv` call sites across 11 files.

**Alias hazard — read this before grepping.** Two files reach `getenv` through
`const posix = std.posix;` rather than the fully qualified name, so a grep for
`std.posix.getenv` finds only 12 of the 23 sites. The full inventory:

| File | Sites | Spelling |
| --- | --- | --- |
| `src/shell.zig` | 639, 658, 768, 769, 937, 965, 996, 1076, 1097 (two on this line) | `posix.getenv` (aliased at `src/shell.zig:5`) |
| `src/config.zig` | 543, 807 | `std.posix.getenv` |
| `src/app/control.zig` | 278, 292 | `std.posix.getenv` |
| `src/app/runtime.zig` | 1491, 1651 | `std.posix.getenv` |
| `src/font_paths.zig` | 113 | `std.posix.getenv` |
| `src/logging.zig` | 50 | `posix.getenv` (aliased at `src/logging.zig:4`) |
| `src/app/worktree.zig` | 46 | `std.posix.getenv` |
| `src/session/notify.zig` | 50 | `std.posix.getenv` |
| `src/session/state.zig` | 769 | `std.posix.getenv` |
| `src/ui/components/worktree_overlay.zig` | 640 | `std.posix.getenv` |
| `src/ui/components/recent_folders_overlay.zig` | 727 | `std.posix.getenv` |

**Interfaces:**
- Consumes: nothing
- Produces: `env.get(key: []const u8) ?[:0]const u8` — the exact return type `std.posix.getenv` had, so no call site needs any coercion change. Task 7 adds `env.init` and swaps the internals.

- [ ] **Step 1: Write the failing test**

Create `src/env.zig` with only the test, so it fails to compile for the right reason:

```zig
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("env.zig is POSIX-only; Architect does not support Windows");
    }
}

test "get returns a value for a variable the process always has" {
    // PATH is guaranteed present in every shell Architect is launched from,
    // including the CI runners and the Nix dev shell.
    const path = get("PATH");
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len > 0);
}

test "get returns null for a variable that is not set" {
    try std.testing.expectEqual(@as(?[:0]const u8, null), get("ARCHITECT_DEFINITELY_NOT_SET_9f3a1c"));
}
```

- [ ] **Step 2: Register the new file in the test registry**

Zig only collects tests from files reachable through `src/main.zig`'s `test` block. Add the import in alphabetical position:

```zig
    _ = @import("colors.zig");
    _ = @import("config.zig");
    _ = @import("env.zig");
    _ = @import("font.zig");
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `nix develop --command zig build test 2>&1 | tail -20`
Expected: FAIL with `use of undeclared identifier 'get'`.

- [ ] **Step 4: Write the minimal implementation**

Add to `src/env.zig`, above the tests:

```zig
/// Process environment access.
///
/// Zig 0.16 removes `std.posix.getenv`, and `std.Io` exposes no environment
/// surface, so environment reads cannot travel with the `io` context the way
/// filesystem and clock reads do. Because the environment is process-global
/// and immutable for Architect's lifetime — exactly what `std.posix.getenv`
/// already assumed — it lives here instead of being threaded through every
/// caller as a second context.
///
/// This is the only sanctioned module-level accessor in the codebase. The
/// `io` context is never stored this way.
pub fn get(key: []const u8) ?[:0]const u8 {
    return std.posix.getenv(key);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

- [ ] **Step 6: Commit the module**

```bash
nix develop --command zig fmt src/
git add src/env.zig src/main.zig
git commit -m "feat(env): add process environment accessor module"
```

- [ ] **Step 7: Route all 12 call sites through `env.get`**

For each file, add the import next to the existing imports and replace the call. The return type is identical, so nothing else changes.

In `src/config.zig`, `src/font_paths.zig`, `src/logging.zig`, `src/shell.zig`:

```zig
const env = @import("env.zig");
```

In `src/app/worktree.zig`, `src/app/runtime.zig`, `src/app/control.zig`, `src/session/notify.zig`, `src/session/state.zig`:

```zig
const env = @import("../env.zig");
```

In `src/ui/components/worktree_overlay.zig` and `src/ui/components/recent_folders_overlay.zig` the path is two levels up:

```zig
const env = @import("../../env.zig");
```

Then replace every `std.posix.getenv(` **and** every aliased `posix.getenv(` with `env.get(`. For example, `src/config.zig:543` becomes:

```zig
    pub fn getPersistencePath(allocator: std.mem.Allocator) ![]u8 {
        const home = env.get("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "persistence.toml" });
    }
```

Leave `src/session/state.zig:770`'s `std.mem.sliceTo(home_z, 0)` exactly as it is. It is redundant but harmless, and removing it would be an unrelated change.

- [ ] **Step 8: Verify no call site was missed**

Use the alias-aware pattern — `std.posix.getenv` alone would report success while 11 aliased sites remain:

Run: `grep -rEn '\b(std\.)?posix\.getenv' src build.zig`
Expected: no output.

Run: `grep -rho 'env\.get(' src | wc -l`
Expected: `23`.

Run: `grep -rl 'env\.get(' src | wc -l`
Expected: `11`.

- [ ] **Step 9: Replace `GeneralPurposeAllocator` with `DebugAllocator`**

`std.heap.GeneralPurposeAllocator` is merely an alias for `std.heap.DebugAllocator` in 0.15.2 (`heap.zig:26`) and is removed in 0.16.

`src/app/runtime.zig:1410`:

```zig
    var gpa = std.heap.DebugAllocator(.{}){};
```

`src/mcp/main.zig:19`:

```zig
    var gpa = std.heap.DebugAllocator(.{}){};
```

Run: `grep -rn 'GeneralPurposeAllocator' src build.zig`
Expected: no output.

- [ ] **Step 10: Verify build, tests, and lint**

Run: `nix develop --command zig build`
Expected: exit 0.

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

Run: `nix develop --command just lint`
Expected: exit 0.

- [ ] **Step 11: Run the app and exercise the env-dependent paths**

Run: `nix develop --command zig build run`
Expected: the window opens. Confirm specifically that config loading worked (no "HomeNotFound" in the log), that the recent-folders overlay lists the home directory, and that `~` abbreviation still appears in the worktree overlay's paths — those are the three user-visible consumers of `env.get`.

- [ ] **Step 12: Format and commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: read environment through env.zig, use DebugAllocator

Zig 0.16 removes both std.posix.getenv and
std.heap.GeneralPurposeAllocator. DebugAllocator is what
GeneralPurposeAllocator already aliases in 0.15.2, so this is a rename."
```

- [ ] **Step 13: Open the PR**

Use the `managing-github` skill.

---

## Step 4: Introduce `src/clock.zig` for timestamps and sleeps

Zig 0.16 removes `std.time.timestamp`, `milliTimestamp`, `nanoTimestamp`, and `std.Thread.sleep`. All 27 sites move behind one module now, so Task 7 only rewrites this file's internals plus adds an `io` argument.

**Files:**
- Create: `src/clock.zig`
- Modify: `src/main.zig` (test registry), and 27 call sites across `src/logging.zig`, `src/app/control.zig`, `src/app/layout.zig`, `src/app/runtime.zig`, `src/session/state.zig`, `src/session/pty_reader.zig`, `src/session/notify.zig`, `src/shell.zig`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `clock.nowSeconds() i64` — replaces `std.time.timestamp()`
  - `clock.nowMillis() i64` — replaces `std.time.milliTimestamp()`
  - `clock.nowNanos() i128` — replaces `std.time.nanoTimestamp()`
  - `clock.sleepNanos(nanoseconds: u64) void` — replaces `std.Thread.sleep()`

  Task 7 prefixes each with an `io: std.Io` parameter and keeps the names and return types unchanged.

- [ ] **Step 1: Write the failing test**

Create `src/clock.zig` with only the tests:

```zig
const std = @import("std");

test "the three clock reads agree on the same instant" {
    const secs = nowSeconds();
    const millis = nowMillis();
    const nanos = nowNanos();

    // All three read the same wall clock, so they must agree once scaled
    // down to seconds. A one-second tolerance absorbs a tick landing
    // between the reads.
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(millis, std.time.ms_per_s))),
        1.0,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(nanos, std.time.ns_per_s))),
        1.0,
    );
}

test "nowSeconds returns a plausible wall-clock time" {
    // 2026-01-01T00:00:00Z. Guards against a clock source that returns
    // uptime or zero instead of Unix time.
    try std.testing.expect(nowSeconds() > 1_767_225_600);
}

test "sleepNanos advances the monotonic reading by at least the requested span" {
    const requested_ns: u64 = 5 * std.time.ns_per_ms;
    const before = nowNanos();
    sleepNanos(requested_ns);
    const elapsed = nowNanos() - before;
    try std.testing.expect(elapsed >= requested_ns);
}
```

- [ ] **Step 2: Register the new file in the test registry**

In `src/main.zig`'s `test` block, in alphabetical position:

```zig
    _ = @import("cli_args.zig");
    _ = @import("clock.zig");
    _ = @import("colors.zig");
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `nix develop --command zig build test 2>&1 | tail -20`
Expected: FAIL with `use of undeclared identifier 'nowSeconds'`.

- [ ] **Step 4: Write the minimal implementation**

Add to `src/clock.zig`, above the tests:

```zig
/// Wall-clock and elapsed-time reads.
///
/// Zig 0.16 removes `std.time.timestamp`, `std.time.milliTimestamp`,
/// `std.time.nanoTimestamp`, and `std.Thread.sleep`, replacing them with
/// `std.Io` clock operations that need an `io` context. Centralizing the
/// reads here keeps that context change out of 27 scattered call sites.
///
/// All three reads use the real (wall) clock, matching what the `std.time`
/// functions did. `nowNanos` is used for frame pacing, which would be better
/// served by a monotonic clock, but switching it is a behavior change and is
/// deliberately out of scope for the toolchain migration.
pub fn nowSeconds() i64 {
    return std.time.timestamp();
}

pub fn nowMillis() i64 {
    return std.time.milliTimestamp();
}

pub fn nowNanos() i128 {
    return std.time.nanoTimestamp();
}

pub fn sleepNanos(nanoseconds: u64) void {
    std.Thread.sleep(nanoseconds);
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

- [ ] **Step 6: Commit the module**

```bash
nix develop --command zig fmt src/
git add src/clock.zig src/main.zig
git commit -m "feat(clock): add time and sleep accessor module"
```

- [ ] **Step 7: Route the 13 timestamp sites through `clock`**

Add `const clock = @import("clock.zig");` (or `@import("../clock.zig")` in `src/app/`, `src/session/`; `@import("../../clock.zig")` under `src/ui/components/`) and replace each call:

| Site | Replace with |
| --- | --- |
| `src/logging.zig:153` | `const now_secs = clock.nowSeconds();` |
| `src/logging.zig:197` | `const timestamp = try timestampToLocalIso8601(clock.nowSeconds(), &timestamp_buf);` |
| `src/app/control.zig:580` | `const deadline_ms = if (timeout_ms) |ms| clock.nowMillis() + ms else null;` |
| `src/app/control.zig:584` | `const now = clock.nowMillis();` |
| `src/app/runtime.zig:1360` | `const start_ns = clock.nowNanos();` |
| `src/app/runtime.zig:1377` | `const now_ns = clock.nowNanos();` |
| `src/app/runtime.zig:1854` | `const frame_start_ns: i128 = clock.nowNanos();` |
| `src/app/runtime.zig:1855` | `const now = clock.nowMillis();` |
| `src/app/runtime.zig:3414` | `last_render_ns = clock.nowNanos();` |
| `src/app/runtime.zig:3427` | `const frame_end_ns: i128 = clock.nowNanos();` |
| `src/app/runtime.zig:3433` | `const now = clock.nowMillis();` |
| `src/app/layout.zig:94` | `const rect = anim_state.getCurrentRect(clock.nowMillis());` |
| `src/session/state.zig:644` | `const processed_at_ms = clock.nowMillis();` |

Note: `src/app/control.zig` is compiled into the separate `control` module for the MCP binary as well as into the main binary, so its import must resolve from `src/app/` — use `@import("../clock.zig")`.

- [ ] **Step 8: Route the 14 sleep sites through `clock`**

| Site | Replace with |
| --- | --- |
| `src/shell.zig:1129` | `clock.sleepNanos(backoff_ns);` |
| `src/app/control.zig:404` | `clock.sleepNanos(std.time.ns_per_ms * 10);` |
| `src/session/pty_reader.zig:274` | `clock.sleepNanos(retry_ns);` |
| `src/session/pty_reader.zig:280` | `clock.sleepNanos(poll_error_backoff_ns);` |
| `src/session/pty_reader.zig:306` | `clock.sleepNanos(5 * std.time.ns_per_ms);` |
| `src/session/pty_reader.zig:532` | `clock.sleepNanos(300 * std.time.ns_per_ms);` |
| `src/session/pty_reader.zig:570` | `clock.sleepNanos(300 * std.time.ns_per_ms);` |
| `src/app/runtime.zig:1248` | `clock.sleepNanos(quit_primary_wait_ms * std.time.ns_per_ms);` |
| `src/app/runtime.zig:1254` | `clock.sleepNanos(quit_retry_wait_ms * std.time.ns_per_ms);` |
| `src/app/runtime.zig:1261` | `clock.sleepNanos(quit_term_wait_ms * std.time.ns_per_ms);` |
| `src/app/runtime.zig:1336` | `clock.sleepNanos(220 * std.time.ns_per_ms);` |
| `src/app/runtime.zig:1383` | `clock.sleepNanos(quit_capture_drain_poll_ns);` |
| `src/session/notify.zig:202` | `clock.sleepNanos(std.time.ns_per_ms * 10);` |
| `src/session/state.zig:1168` | `clock.sleepNanos(50 * std.time.ns_per_ms);` |

`std.time.ns_per_ms` and friends are compile-time constants that survive into 0.16 — leave them alone.

- [ ] **Step 9: Verify no call site was missed**

Run: `grep -rn 'std\.time\.\(milliTimestamp\|nanoTimestamp\|timestamp\)' src`
Expected: no output.

Run: `grep -rn 'std\.Thread\.sleep' src`
Expected: no output.

- [ ] **Step 10: Verify build, tests, and lint**

Run: `nix develop --command zig build`
Expected: exit 0.

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

Run: `nix develop --command just lint`
Expected: exit 0.

- [ ] **Step 11: Verify the timing-sensitive behavior by hand**

Timestamps drive animation and log rotation, which no unit test covers. Run: `nix develop --command zig build run` and confirm: the layout expand/collapse animation still runs smoothly (not instant, not frozen) — that exercises `layout.zig:94`; the log file under the log directory carries correct ISO-8601 timestamps — that exercises `logging.zig:197`; and quitting with a busy session still shows the shimmer overlay for its normal duration rather than hanging or returning instantly — that exercises the `runtime.zig` quit sleeps.

- [ ] **Step 12: Format and commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: read time and sleep through clock.zig

Zig 0.16 removes std.time's timestamp functions and std.Thread.sleep in
favor of std.Io clock operations that require an io context. Centralizing
the 27 sites now keeps that change out of every caller."
```

---

## Step 5: Introduce `src/proc.zig` for command execution

Zig 0.16 keeps `std.process.Child` as a type but reduces its methods to `kill(io)` and `wait(io)`. `Child.init`, `spawn`, `spawnAndWait`, and `collectOutput` are gone; `std.process.spawn(io, opts)` and `std.process.run(gpa, io, opts)` replace them. Four of the seven sites share one pattern — run a command, collect stdout and stderr, inspect the term — which maps exactly onto `std.process.run`.

This task and Task 4 belong to the same PR (Prep 3).

**Files:**
- Create: `src/proc.zig`
- Modify: `src/main.zig` (test registry), `src/os/open.zig:59`, `src/ui/components/pr_dropdown_fetch.zig:18-62`, `src/ui/components/diff_overlay.zig:125,550,612`, `src/app/runtime.zig:2958`, `src/shell.zig:1183-1188`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `proc.Term = union(enum) { exited: u8, signal: u32, stopped: u32, unknown: u32 }` — Architect's own term type, deliberately using 0.16's lowercase tag names so the flip does not have to touch every `switch`
  - `proc.RunResult = struct { term: Term, stdout: []u8, stderr: []u8 }` — caller owns `stdout` and `stderr`
  - `proc.RunOptions = struct { argv: []const []const u8, cwd: ?[]const u8 = null, max_output_bytes: usize = 4 * 1024 * 1024 }`
  - `proc.run(allocator: std.mem.Allocator, options: RunOptions) !RunResult`
  - `proc.spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !Term` — spawn, wait, discard output

  Task 7 prefixes both functions with an `io: std.Io` parameter and swaps the internals.

- [ ] **Step 1: Write the failing test**

Create `src/proc.zig` with only the tests. These use `/bin/sh`, which is present on both macOS and Linux:

```zig
const std = @import("std");

test "run collects stdout and reports a zero exit" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "run separates stderr from stdout and reports a nonzero exit" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(Term{ .exited = 3 }, result.term);
}

test "run honors cwd" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .cwd = "/",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("/\n", result.stdout);
}

test "run surfaces a missing executable as an error rather than a term" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, run(allocator, .{
        .argv = &.{"/nonexistent/architect-test-binary"},
    }));
}

test "spawnDetached waits for the child and returns its term" {
    const allocator = std.testing.allocator;
    const term = try spawnDetached(allocator, &.{ "/bin/sh", "-c", "exit 7" });
    try std.testing.expectEqual(Term{ .exited = 7 }, term);
}
```

- [ ] **Step 2: Register the new file in the test registry**

In `src/main.zig`'s `test` block, in alphabetical position:

```zig
    _ = @import("platform/sdl.zig");
    _ = @import("proc.zig");
    _ = @import("pty.zig");
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `nix develop --command zig build test 2>&1 | tail -20`
Expected: FAIL with `use of undeclared identifier 'run'`.

- [ ] **Step 4: Write the minimal implementation**

Add to `src/proc.zig`, above the tests:

```zig
/// Child-process execution.
///
/// Zig 0.16 reduces `std.process.Child` to `kill` and `wait`, moving creation
/// to `std.process.spawn(io, ...)` and the collect-output pattern to
/// `std.process.run(gpa, io, ...)`. Both need an `io` context. Centralizing
/// the two shapes Architect actually uses keeps that change out of the call
/// sites.
///
/// `Term` mirrors `std.process.Child.Term` but is declared here with 0.16's
/// lowercase tag names, so callers' `switch` arms do not change at the
/// toolchain bump.
pub const Term = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const RunResult = struct {
    term: Term,
    /// Caller owns this memory.
    stdout: []u8,
    /// Caller owns this memory.
    stderr: []u8,
};

pub const RunOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 4 * 1024 * 1024,
};

fn fromStdTerm(term: std.process.Child.Term) Term {
    return switch (term) {
        .Exited => |code| .{ .exited = code },
        .Signal => |sig| .{ .signal = sig },
        .Stopped => |sig| .{ .stopped = sig },
        .Unknown => |code| .{ .unknown = code },
    };
}

/// Runs `argv` to completion, collecting stdout and stderr.
pub fn run(allocator: std.mem.Allocator, options: RunOptions) !RunResult {
    var child = std.process.Child.init(options.argv, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stderr_buf.deinit(allocator);

    errdefer child.kill() catch |err| {
        std.log.scoped(.proc).warn("failed to stop child after output failure: {}", .{err});
    };

    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, options.max_output_bytes);
    const term = try child.wait();

    const stdout_slice = try stdout_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try stderr_buf.toOwnedSlice(allocator);

    return .{
        .term = fromStdTerm(term),
        .stdout = stdout_slice,
        .stderr = stderr_slice,
    };
}

/// Spawns `argv`, waits for it, and discards its output.
pub fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !Term {
    var child = std.process.Child.init(argv, allocator);
    return fromStdTerm(try child.spawnAndWait());
}
```

**One intentional deviation from "no behavior change".** `run` sets
`stdin_behavior = .Ignore`, whereas `pr_dropdown_fetch.zig` and
`diff_overlay.zig` currently inherit the parent's stdin. This is unavoidable:
0.16's `std.process.run` hardcodes `.stdin = .ignore`, so the behavior changes
at the flip regardless. Making it explicit here means it is exercised and
tested under 0.15.2 rather than arriving unnoticed with the toolchain bump.
Neither `gh pr list` nor `git diff` reads stdin, so no observable behavior
changes — but verify the manual checks in Step 14 rather than assuming.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

- [ ] **Step 6: Commit the module**

```bash
nix develop --command zig fmt src/
git add src/proc.zig src/main.zig
git commit -m "feat(proc): add child-process execution module

run() ignores stdin because 0.16's std.process.run hardcodes that; landing
it now means the change is tested under the current toolchain."
```

- [ ] **Step 7: Convert `src/os/open.zig`**

`openUrlThread` spawns and waits, discarding output. Replace the body:

```zig
fn openUrlThread(ctx: *ThreadContext) void {
    defer ctx.deinit();

    _ = proc.spawnDetached(ctx.allocator, &ctx.argv) catch |err| {
        log.warn("failed to open URL '{s}': {}", .{ ctx.url, err });
        return;
    };
}
```

Add `const proc = @import("../proc.zig");` to the imports.

- [ ] **Step 8: Convert `src/app/runtime.zig:2958`**

The `open -t <config_path>` invocation also discards output:

```zig
                            _ = proc.spawnDetached(allocator, &.{ "open", "-t", config_path }) catch |err| {
                                log.warn("failed to open config in editor: {}", .{err});
                            };
```

Preserve whatever the surrounding error handling currently does; if the existing code already logs, keep the same message and level.

- [ ] **Step 9: Convert `src/ui/components/pr_dropdown_fetch.zig`**

This is the collect-output shape. Replace the whole spawn-collect-wait sequence in `runGhPrList` with a single `proc.run` call, keeping every existing log message and `FetchResult` branch:

```zig
    const result = proc.run(allocator, .{
        .argv = &argv,
        .cwd = cwd,
    }) catch |err| {
        if (err == error.FileNotFound) {
            log.err("gh CLI not found while listing pull requests: cwd={s}", .{cwd});
            return model.FetchResult{
                .status = .gh_missing,
                .prs = &[_]model.PullRequest{},
                .error_message = null,
            };
        }
        log.err("failed to run gh while listing pull requests: cwd={s} error={s}", .{ cwd, @errorName(err) });
        return buildFetchError(allocator, "Failed to launch gh: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
```

Then update the term switch at line 62 to the lowercase tag:

```zig
    switch (result.term) {
        .exited => |code| {
```

Add `const proc = @import("../../proc.zig");` to the imports.

- [ ] **Step 10: Convert `src/ui/components/diff_overlay.zig`**

Change the field type at line 125:

```zig
    term: proc.Term,
```

Replace the `Child.init` block at line 550 with `proc.run`, and update the term switch at line 612:

```zig
            .exited => |code| if (code == 0)
```

Add `const proc = @import("../../proc.zig");` to the imports. Read the surrounding 40 lines before editing so the existing error branches and buffer ownership are preserved exactly.

- [ ] **Step 11: Convert the `src/shell.zig` test**

Lines 1183-1188 run `tic` in a test. Replace with:

```zig
    const term = try proc.spawnDetached(allocator, &.{ tic_path, "-x", "-o", tmp_path, src_path });
    try testing.expectEqual(proc.Term{ .exited = 0 }, term);
```

Add `const proc = @import("proc.zig");` to the imports.

- [ ] **Step 12: Verify no call site was missed**

Run: `grep -rn 'std\.process\.Child' src`
Expected: only `src/proc.zig` (the wrapper's own internals).

Run: `grep -rn '\.Exited\|\.Signal\b\|\.Stopped\b' src | grep -v 'src/proc.zig'`
Expected: no output.

- [ ] **Step 13: Verify build, tests, and lint**

Run: `nix develop --command zig build`
Expected: exit 0.

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

Run: `nix develop --command just lint`
Expected: exit 0.

- [ ] **Step 14: Verify the subprocess behavior by hand**

Run: `nix develop --command zig build run`, then: press ⌘P to open the PR dropdown in a git repo with open pull requests and confirm the list populates (exercises `pr_dropdown_fetch.zig`); open the diff overlay and confirm the diff renders (exercises `diff_overlay.zig`); click a URL in terminal output and confirm it opens in the browser (exercises `os/open.zig`); trigger "open config" and confirm the editor launches (exercises `runtime.zig:2958`). Also confirm the PR dropdown shows its "gh not found" state when `gh` is absent from `PATH` — that branch is the one most likely to be broken by the error-mapping change.

- [ ] **Step 15: Format and commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: run child processes through proc.zig

Zig 0.16 removes Child.init, spawn, spawnAndWait, and collectOutput,
replacing them with std.process.spawn/run, which need an io context.
proc.Term uses 0.16's lowercase tag names so caller switches are final."
```

- [ ] **Step 16: Open the Prep 3 PR**

Use the `managing-github` skill. This PR contains Task 4 and Task 5.

---

**One branch, one PR, tasks 6 through 15.** Architect cannot build on both toolchains, so `zig build` will fail throughout Tasks 6–12. Each task's gate is the disappearance of a *specific error class* from the captured build log, not a green build. Task 13 is the green gate.

Create the branch once, at the start of Task 6:

```bash
git checkout main && git pull origin main
git checkout -b feat/zig-0-16
```

Throughout the flip, capture the build log with:

```bash
nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true
grep -c "error:" .tmp/flip-errors.txt
```

### The 0.16 API mapping

Every filesystem transformation in Tasks 6, 10, and 11 comes from this table, verified against `lib/std/Io/Dir.zig` and `lib/std/Io/File.zig` at tag `0.16.0`. **Note the two irregularities:** `renameAbsolute` takes `io` *last*, and `makeDirAbsolute`/`makePath` are renamed rather than merely gaining a parameter.

| Zig 0.15.2 | Zig 0.16.0 |
| --- | --- |
| `std.fs.File` | `std.Io.File` |
| `std.fs.Dir` | `std.Io.Dir` |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` — takes no `io` |
| `std.fs.File.stdin()` / `.stdout()` / `.stderr()` | `std.Io.File.stdin()` / `.stdout()` / `.stderr()` — take no `io` |
| `std.fs.openFileAbsolute(p, opts)` | `std.Io.Dir.openFileAbsolute(io, p, opts)` |
| `std.fs.openDirAbsolute(p, opts)` | `std.Io.Dir.openDirAbsolute(io, p, opts)` |
| `std.fs.createFileAbsolute(p, flags)` | `std.Io.Dir.createFileAbsolute(io, p, flags)` |
| `std.fs.accessAbsolute(p, opts)` | `std.Io.Dir.accessAbsolute(io, p, opts)` |
| `std.fs.deleteFileAbsolute(p)` | `std.Io.Dir.deleteFileAbsolute(io, p)` |
| `std.fs.makeDirAbsolute(p)` | `std.Io.Dir.createDirAbsolute(io, p, .default_dir)` |
| `dir.makePath(p)` | `dir.createDirPath(io, p)` |
| `dir.realpathAlloc(gpa, p)` | `dir.realPathFileAlloc(io, p, gpa)` — note the argument order |
| `std.fs.renameAbsolute(old, new)` | `std.Io.Dir.renameAbsolute(old, new, io)` — **`io` is last** |
| `dir.deleteTree(p)` | `dir.deleteTree(io, p)` |
| `dir.close()` | `dir.close(io)` |
| `dir.iterate()` then `it.next()` | `dir.iterate()` (no `io`) then `it.next(io)` |
| `file.close()` | `file.close(io)` |
| `file.stat()` | `file.stat(io)` |
| `file.sync()` | `file.sync(io)` |
| `file.read(buf)` | `file.readStreaming(io, &.{buf})` |
| `file.writeAll(bytes)` | `file.writeStreamingAll(io, bytes)` |
| `fs.File.OpenError`, `ReadError`, `WriteError`, `SyncError` | `std.Io.File.OpenError`, and so on |
| `fs.Dir.MakeError` | `std.Io.Dir.CreateDirError` |
| `fs.Dir.OpenError` | `std.Io.Dir.OpenError` |

`Permissions.default_dir` is `0o777` in 0.16 where 0.15's `makeDirAbsolute` used `0o755`. Both are masked by the process umask (`0o022` in every environment Architect runs in), giving the same `0o755` on disk. This is not a behavior change.

---

## Step 6: Flip the toolchain, dependency pins, and `build.zig`

**Files:**
- Modify: `flake.nix:49`, `build.zig.zon`, `build.zig`

**Interfaces:**
- Consumes: the four verified hashes from Task 1
- Produces: a `build.zig` that 0.16 can execute, so the compiler reaches `src/`

- [ ] **Step 1: Bump the toolchain in `flake.nix`**

```nix
            zig.packages.${system}."0.16.0"
```

Leave the macOS SDK workaround block alone for now; Task 14 handles it.

- [ ] **Step 2: Bump `build.zig.zon`**

Use the hashes recorded in `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md` from Task 1 Step 4. Do not invent hashes; if the inventory is missing any, re-run `zig fetch` for that URL.

```zig
.{
    .name = .architect,
    .version = "0.1.0",
    .fingerprint = 0x3a466a9634a65f7c,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .ghostty = .{
            .url = "https://github.com/ghostty-org/ghostty/archive/76e568b475fe88f5506be33ad1a684f3c1eae85e.tar.gz",
            .hash = "<hash recorded in Task 1 Step 4 for this exact URL>",
        },
        .libxev = .{
            .url = "https://deps.files.ghostty.org/libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz",
            .hash = "libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F",
        },
        .toml = .{
            .url = "https://github.com/sam701/zig-toml/archive/8685923e32e8b8a795eb2715684236975a70faed.tar.gz",
            .hash = "<hash recorded in Task 1 Step 4 for this exact URL>",
        },
        .zwanzig = .{
            .url = "https://github.com/forketyfork/zwanzig/archive/refs/tags/v0.15.1.tar.gz",
            .hash = "<hash recorded in Task 1 Step 4 for this exact URL>",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

The `zwanzig` URL is unchanged — v0.15.1's `src/compat.zig` already supports 0.16.0 — but its hash must still be regenerated if 0.16 changed the hash format.

- [ ] **Step 3: Rename the build graph's env map**

`std.Build.Graph.env_map` is `environ_map` in 0.16. Task 2 already routed all four reads through the graph, so this is a mechanical rename of four occurrences in `build.zig`:

```zig
    if (b.graph.environ_map.get("SDL3_INCLUDE_PATH")) |sdl3_include| {
```

Run: `grep -c 'b\.graph\.environ_map\.get' build.zig`
Expected: `4`.

- [ ] **Step 4: Convert `build.zig`'s filesystem and subprocess calls**

`sdkExists` uses `std.fs.openDirAbsolute` and `findXcrunSdkRoot` uses `std.process.Child.run`. Both need `io`, which comes from `b.graph.io`. Thread it as a parameter rather than reaching for a global:

```zig
fn findXcrunSdkRoot(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) {
        return result.stdout;
    }

    defer allocator.free(result.stdout);
    return allocator.dupe(u8, trimmed) catch null;
}

fn sdkExists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.openDirAbsolute(io, path, .{})) |dir_const| {
        var dir = dir_const;
        dir.close(io);
        return true;
    } else |_| {
        return false;
    }
}
```

Note the `Term` tag is now lowercase `.exited`. Update the three callers to pass `io`: `findSdkRoot` becomes `findSdkRoot(b)` still (it has `b`, so it uses `b.graph.io` internally and passes it down), `findDeveloperDirSdkRoot(b)` likewise, and each `sdkExists(candidate)` call becomes `sdkExists(b.graph.io, candidate)`, with `findXcrunSdkRoot(b.allocator)` becoming `findXcrunSdkRoot(b.allocator, b.graph.io)`.

- [ ] **Step 5: Verify `build.zig` itself compiles under 0.16**

Run: `nix develop --command bash -c 'zig build --help > /dev/null'`
Expected: exit 0. This executes the build script without building the project, isolating build-script errors from source errors. If it fails, the diagnostics are all in `build.zig` — fix them before continuing.

- [ ] **Step 6: Confirm dependency resolution and capture the source error baseline**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -niE 'ghostty|libxev|toml|zwanzig' .tmp/flip-errors.txt`
Expected: no output. Any dependency-resolution error here is a Task 1 regression — stop and re-check the pins.

Run: `grep -c 'error:' .tmp/flip-errors.txt`
Expected: a large number, all pointing into `src/`. Record it; later tasks compare against it.

- [ ] **Step 7: Commit**

```bash
git add flake.nix build.zig.zon build.zig
git commit -m "build: flip toolchain and dependencies to Zig 0.16.0

ghostty moves to a main-branch commit because 1.3.2-dev is the first line
requiring 0.16.0 and no v1.3.2 tag exists yet; libxev follows ghostty's pin;
zig-toml moves to its zig-0.16 branch. zwanzig v0.15.1 already supports
0.16.0 through its compat layer and needs no version change.

src/ does not compile yet; the following commits on this branch complete
the migration."
```

---

## Step 7: Convert the entry points and the three wrapper modules

**Files:**
- Modify: `src/main.zig:14-25`, `src/mcp/main.zig:18-21`, `src/env.zig`, `src/clock.zig`, `src/proc.zig`

**Interfaces:**
- Consumes: `env.get`, `clock.nowSeconds`/`nowMillis`/`nowNanos`/`sleepNanos`, `proc.run`/`spawnDetached`/`Term` from Tasks 3–5
- Produces:
  - `env.init(environ: std.process.Environ) void` — called exactly once per process, before any thread is spawned
  - `env.get(key: []const u8) ?[:0]const u8` — unchanged signature
  - `clock.nowSeconds(io: std.Io) i64`, `clock.nowMillis(io: std.Io) i64`, `clock.nowNanos(io: std.Io) i128`, `clock.sleepNanos(io: std.Io, nanoseconds: u64) void`
  - `proc.run(allocator: std.mem.Allocator, io: std.Io, options: RunOptions) !RunResult`, `proc.spawnDetached(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Term`
  - `proc.Term` is unchanged (`exited`/`signal`/`stopped`/`unknown`, `signal: u32`)

- [ ] **Step 1: Convert `src/main.zig` to take `std.process.Init`**

`std.process.Init` supplies `io`, `gpa`, `arena`, and `environ_map`; `std.process.argsAlloc` is gone and arguments arrive through `init.minimal.args`.

```zig
pub fn main(init: std.process.Init) !void {
    env.init(init.minimal.environ);

    var args = init.minimal.args;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    while (args.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    const parsed = cli_args.parse(argv.items[1..]) catch |err| {
        std.debug.print("architect: {s}\n{s}", .{ @errorName(err), cli_args.usage_text });
        std.process.exit(1);
    };

    try runtime.run(init.io, parsed.log_dir_override);
}
```

Add `const env = @import("env.zig");` to the imports.

If `std.process.Args.Iterator`'s exact method name differs from `next()`, read `lib/std/process/Args.zig` in the 0.16 lib directory (`$(dirname $(readlink -f $(which zig)))/../lib/std/process/Args.zig`) and use the real name. Do not guess.

- [ ] **Step 2: Convert `src/mcp/main.zig`**

```zig
pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, std.Io.File.stdin(), std.Io.File.stdout());
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
```

`init.gpa` replaces the `DebugAllocator` entirely, so the `var gpa` / `defer _ = gpa.deinit()` lines are deleted.

- [ ] **Step 3: Convert `src/env.zig` internals**

```zig
var process_environ: ?std.process.Environ = null;

/// Must be called exactly once, from `main`, before any thread is spawned.
pub fn init(environ: std.process.Environ) void {
    std.debug.assert(process_environ == null);
    process_environ = environ;
}

pub fn get(key: []const u8) ?[:0]const u8 {
    const environ = process_environ orelse
        @panic("env.get called before env.init; main must call env.init first");
    return environ.getPosix(key);
}
```

The panic is deliberate: a read before initialization is a programming error with no correct recovery, and returning `null` would silently hide it.

- [ ] **Step 4: Fix `src/env.zig`'s tests for the new initialization requirement**

The tests call `get` without a `main`, so they must initialize first. The test binary's environment is reachable through `std.process.Environ`:

```zig
fn initForTest() void {
    if (process_environ == null) {
        process_environ = .{ .block = .global };
    }
}

test "get returns a value for a variable the process always has" {
    initForTest();
    const path = get("PATH");
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len > 0);
}

test "get returns null for a variable that is not set" {
    initForTest();
    try std.testing.expectEqual(@as(?[:0]const u8, null), get("ARCHITECT_DEFINITELY_NOT_SET_9f3a1c"));
}
```

`.global` is the process-wide environ block; confirm the exact spelling against `lib/std/process/Environ.zig:35` (`pub const GlobalBlock`) in the installed 0.16 lib directory and use whatever constructor it actually provides. Do not guess.

- [ ] **Step 5: Convert `src/clock.zig` internals**

```zig
pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn nowNanos(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .real).toNanoseconds();
}

pub fn sleepNanos(io: std.Io, nanoseconds: u64) void {
    std.Io.sleep(io, .fromNanoseconds(@intCast(nanoseconds)), .awake) catch |err| {
        std.log.scoped(.clock).warn("sleep interrupted: {}", .{err});
    };
}
```

`.real` is 0.16's wall clock — the enum tags are `real`, `awake`, `boot`, `cpu_process`, `cpu_thread`, not `realtime`/`monotonic`. `.real` preserves what `std.time.timestamp`/`milliTimestamp`/`nanoTimestamp` did.

`sleepNanos` uses `.awake`, which is `CLOCK_UPTIME_RAW` on macOS and `CLOCK_MONOTONIC` on Linux — the closest match to `std.Thread.sleep`'s "wait this much elapsed time". `std.Io.sleep` returns `Cancelable!void` and there is no uncancelable variant; Architect never requests cancellation, so `error.Canceled` cannot occur, and it is logged rather than swallowed per `CLAUDE.md`.

`Timestamp.nanoseconds` is `i96`; `toNanoseconds()` returns `i96`, which widens losslessly to the `i128` callers expect.

- [ ] **Step 6: Update `src/clock.zig`'s tests to pass `io`**

Tests need their own `Io`. Create one per test:

```zig
test "the three clock reads agree on the same instant" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secs = nowSeconds(io);
    const millis = nowMillis(io);
    const nanos = nowNanos(io);

    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(millis, std.time.ms_per_s))),
        1.0,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(nanos, std.time.ns_per_s))),
        1.0,
    );
}

test "nowSeconds returns a plausible wall-clock time" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expect(nowSeconds(threaded.io()) > 1_767_225_600);
}

test "sleepNanos advances the clock by at least the requested span" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const requested_ns: u64 = 5 * std.time.ns_per_ms;
    const before = nowNanos(io);
    sleepNanos(io, requested_ns);
    try std.testing.expect(nowNanos(io) - before >= requested_ns);
}
```

- [ ] **Step 7: Convert `src/proc.zig` internals**

`std.process.run` covers the collect-output shape exactly, including `cwd` and output limits. `std.process.spawn` plus `Child.wait` covers the spawn-and-wait shape.

```zig
fn fromStdTerm(term: std.process.Child.Term) Term {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        .stopped => |sig| .{ .stopped = @intFromEnum(sig) },
        .unknown => |code| .{ .unknown = code },
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: RunOptions) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .stdout_limit = .limited(options.max_output_bytes),
        .stderr_limit = .limited(options.max_output_bytes),
    });
    return .{
        .term = fromStdTerm(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn spawnDetached(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Term {
    _ = allocator;
    var child = try std.process.spawn(io, .{ .argv = argv });
    return fromStdTerm(try child.wait(io));
}
```

`Term.signal` and `Term.stopped` carry `std.posix.SIG` in 0.16 rather than `u32`; `@intFromEnum` keeps `proc.Term`'s own `u32` payload so no caller `switch` changes. `Child.Cwd` is a union, so a plain `?[]const u8` becomes `.{ .path = c }` or `.inherit`.

`spawnDetached` keeps its `allocator` parameter (discarded) so the four call sites do not change shape; drop the parameter only if a reviewer asks.

- [ ] **Step 8: Update `src/proc.zig`'s tests to pass `io`**

Prefix each test with the same `std.Io.Threaded` setup shown in Step 6 and thread `io` into every `run` / `spawnDetached` call. For example:

```zig
test "run collects stdout and reports a zero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    const result = try run(allocator, threaded.io(), .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}
```

- [ ] **Step 9: Verify the error class shrank**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -nE 'argsAlloc|GeneralPurposeAllocator|std\.time\.(timestamp|milliTimestamp|nanoTimestamp)|std\.Thread\.sleep' .tmp/flip-errors.txt`
Expected: no output. The entry-point, allocator, time, and sleep error classes are gone; the remaining errors are missing-`io` errors at the call sites Tasks 8–12 fix.

- [ ] **Step 10: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: take std.process.Init and move wrappers to std.Io

env, clock, and proc now take the io context that Zig 0.16 requires."
```

---

## Step 8: Thread `io` through the app and session layers

`io` follows the paths `allocator` already follows. Work outward from `runtime.run`, which received `init.io` in Task 7, and let the compiler drive: each "expected 3 arguments, found 2" error names the next signature to widen.

**Files:**
- Modify: `src/app/runtime.zig`, `src/app/control.zig`, `src/app/layout.zig`, `src/app/worktree.zig`, `src/session/state.zig`, `src/session/pty_reader.zig`, `src/session/notify.zig`, `src/shell.zig`, `src/config.zig`, `src/logging.zig`, `src/font_paths.zig`

**Interfaces:**
- Consumes: `clock.*(io, ...)`, `proc.*(allocator, io, ...)` from Task 7
- Produces: every struct in these files that owns an `allocator` field also owns an `io: std.Io` field, placed immediately after it; every function that takes an `allocator` parameter and reaches a `clock`, `proc`, or filesystem call also takes `io: std.Io` immediately after it. `runtime.run(io: std.Io, log_dir_override: ?[]const u8) !void`.

- [ ] **Step 1: Widen `runtime.run`**

```zig
pub fn run(io: std.Io, log_dir_override: ?[]const u8) !void {
```

Task 7 Step 1 already calls it this way.

- [ ] **Step 2: Add the `io` field to every struct that owns an `allocator`**

The convention, applied uniformly: `io` goes immediately after `allocator`, and every `init` that takes an allocator takes `io` immediately after it. For example, in `src/session/state.zig`:

```zig
pub const SessionState = struct {
    slot_index: usize,
    id: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    shell: ?shell_mod.Shell,
```

(place `io` next to wherever `allocator` already sits in each struct — do not reorder the other fields)

- [ ] **Step 3: Thread `io` into thread-context structs**

Spawned threads outlive their spawner's stack frame, so `io` must be *stored*, not borrowed. Every context struct passed to `std.Thread.spawn` gains an `io` field. The affected spawn sites are `src/app/control.zig:355`, `src/app/runtime.zig:1232`, `src/app/runtime.zig:1306`, `src/session/notify.zig:260`, `src/session/pty_reader.zig:261`, `src/ui/components/pr_dropdown.zig:584`, and `src/os/open.zig:47`.

`src/os/open.zig`'s `ThreadContext` already carries `allocator`, so add `io` beside it and use `ctx.io` in `openUrlThread`:

```zig
    _ = proc.spawnDetached(ctx.allocator, ctx.io, &ctx.argv) catch |err| {
        log.warn("failed to open URL '{s}': {}", .{ ctx.url, err });
        return;
    };
```

`std.Io` is a fat pointer (vtable plus userdata) and the `std.Io.Threaded` instance it points at lives for the whole process, so storing a copy per context is safe.

- [ ] **Step 4: Widen the `clock` call sites**

All 27 sites from Task 4 now need `io` as the first argument. Where the enclosing function is a method on a struct that gained an `io` field in Step 2, use `self.io`; otherwise use the function's new `io` parameter. For example `src/app/layout.zig:94`:

```zig
            const rect = anim_state.getCurrentRect(clock.nowMillis(io));
```

and `src/session/state.zig:644`:

```zig
            const processed_at_ms = clock.nowMillis(self.io);
```

- [ ] **Step 5: Widen the `proc` call sites in this layer**

`src/app/runtime.zig:2958`:

```zig
                            _ = proc.spawnDetached(allocator, io, &.{ "open", "-t", config_path }) catch |err| {
                                log.warn("failed to open config in editor: {}", .{err});
                            };
```

`src/shell.zig`'s test at line 1183:

```zig
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const term = try proc.spawnDetached(allocator, threaded.io(), &.{ tic_path, "-x", "-o", tmp_path, src_path });
    try testing.expectEqual(proc.Term{ .exited = 0 }, term);
```

- [ ] **Step 6: Verify the error class shrank**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -nE 'clock\.(now|sleep)|proc\.(run|spawnDetached)' .tmp/flip-errors.txt`
Expected: no output. Remaining errors should be filesystem and mutex errors only, plus UI-layer `io` plumbing.

- [ ] **Step 7: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor(app): thread io through the app and session layers"
```

---

## Step 9: Thread `io` through the UI layer

Six components do filesystem, subprocess, or synchronization work and therefore need `io`. They receive it in their own `init`, which `src/app/runtime.zig` calls with `io` already in scope — so `UiRoot` needs no `io` of its own, and must not be given one speculatively.

**Files:**
- Modify: `src/ui/components/diff_overlay.zig` (filesystem + subprocess), `src/ui/components/pr_dropdown.zig` (mutex + spawned thread), `src/ui/components/pr_dropdown_fetch.zig` (subprocess), `src/ui/components/pr_dropdown_repo.zig` (filesystem), `src/ui/components/worktree_overlay.zig` (filesystem), `src/ui/components/story_overlay.zig` (filesystem), and the corresponding `init` call sites in `src/app/runtime.zig`

**Do not modify:** `src/ui/root.zig`, `src/ui/components/cwd_bar.zig`, `src/ui/components/recent_folders_overlay.zig`. `UiRoot` is only a registry and needs no `io`; `cwd_bar.zig` does no IO at all; `recent_folders_overlay.zig` reads only the environment, and `env.get` takes no `io`. Verify this before adding a field:

Run: `grep -nE '\b(std\.)?fs\.[A-Za-z_]+|std\.time\.(milli|nano|timestamp)|std\.Thread|process\.Child' src/ui/root.zig src/ui/components/cwd_bar.zig src/ui/components/recent_folders_overlay.zig | grep -vE 'fs\.(path|max_)'`
Expected: no output.

**Interfaces:**
- Consumes: `clock.*(io, ...)`, `proc.*(allocator, io, ...)` from Task 7; `io` available in `src/app/runtime.zig` from Task 8
- Produces: each of the six components carries an `io: std.Io` field immediately after its `allocator` field, set from its `init`'s new `io` parameter; `runGhPrList(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) model.FetchResult`

- [ ] **Step 1: Add the `io` field and `init` parameter to each of the six components**

The convention matches Task 8 Step 2: `io` sits immediately after `allocator` in the struct, and `init` takes `io` immediately after its allocator parameter. Do not reorder any other field. Update each component's `init` call in `src/app/runtime.zig` to pass `io`.

- [ ] **Step 2: Thread `io` into the PR dropdown's fetch thread context**

`src/ui/components/pr_dropdown.zig:584` spawns a fetch thread whose context outlives the spawning stack frame, so the context struct must store its own `io` copy rather than borrow one:

```zig
    const thread = std.Thread.spawn(.{}, fetchThreadMain, .{ctx}) catch |err| {
```

with `ctx` gaining an `io` field alongside its existing allocator. `runGhPrList` then takes `io`:

```zig
pub fn runGhPrList(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) model.FetchResult {
```

and the `proc.run` call inside it becomes:

```zig
    const result = proc.run(allocator, io, .{
        .argv = &argv,
        .cwd = cwd,
    }) catch |err| {
```

Keep every existing `log.err` message and `model.FetchResult` branch exactly as Task 5 left them.

- [ ] **Step 3: Widen the `diff_overlay.zig` subprocess call**

```zig
    const result = proc.run(self.allocator, self.io, .{
        .argv = argv,
        .cwd = repo_root,
    }) catch |err| {
```

Read the surrounding 40 lines first and keep every existing error branch, and the consumers of the `term: proc.Term` field, unchanged.

- [ ] **Step 4: Widen the PR dropdown's mutex operations**

`src/ui/components/pr_dropdown.zig:25` declares a mutex. Task 12 converts the declaration; here, only ensure `io` is reachable at each lock site — either as `self.io` or via the thread context from Step 2.

- [ ] **Step 5: Verify the error class shrank**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -n 'src/ui/' .tmp/flip-errors.txt | grep -vE 'std\.fs|std\.Io\.(Dir|File)|Mutex|Condition'`
Expected: no output. Remaining UI errors are filesystem and mutex errors, handled by Tasks 11 and 12.

- [ ] **Step 6: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor(ui): thread io through the components that need it"
```

---

## Step 10: Convert the filesystem calls in the core files

65 of the 84 source filesystem sites live in six non-UI files. Use the API mapping table above for every transformation.

**Files:**
- Modify: `src/shell.zig` (16 sites), `src/config.zig` (14), `src/mcp/main.zig` (13), `src/logging.zig` (11), `src/font_paths.zig` (6), `src/app/control.zig` (5)

**Interfaces:**
- Consumes: `io` threaded in by Task 8; `std.Io.Dir` / `std.Io.File` per the mapping table
- Produces: no `fs.` filesystem calls remain in these files

- [ ] **Step 1: Note the alias hazard before you start**

`src/config.zig:2` and `src/logging.zig:3` declare `const fs = std.fs;`, and `src/session/state.zig:9` does too. A grep for `std.fs.` will miss every site in those files. Update the aliases first so the compiler finds the sites for you:

```zig
const fs = std.fs; // keep: still used for fs.path.* and fs.max_path_bytes
const Dir = std.Io.Dir;
const File = std.Io.File;
```

`fs.path.*` and `fs.max_path_bytes` survive in 0.16, so the `fs` alias stays for those uses only.

- [ ] **Step 2: Convert `src/config.zig`**

**Check the toml drift finding first.** `src/config.zig` is the only consumer of the `toml` dependency, which moved to an untagged branch in Task 6. Read the Risk 4 verdict in `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md` before editing. If the parser API drifted, fix that in this step and be careful of the two hazards `CLAUDE.md` records: parser-owned maps must not outlive `result.deinit()`, and persisted map keys *and* values must both be duplicated into your own storage. A use-after-free here is a segfault at config load, not a compile error.

Nine call sites plus five error-set references. The error sets at lines 945 and 953:

```zig
} || File.OpenError || File.ReadError;
```

```zig
} || File.OpenError || File.WriteError || File.SyncError || Dir.CreateDirError || Dir.OpenError || std.posix.RenameError;
```

The calls, in order: line 372 `Dir.openFileAbsolute(io, persistence_path, .{})`; line 469 `Dir.createDirAbsolute(io, persistence_dir, .default_dir)`; line 774 `Dir.openDirAbsolute(io, dir_path, .{})`; line 816 `Dir.createDirAbsolute(io, config_dir, .default_dir)`; line 891 `Dir.openFileAbsolute(io, config_path, .{})`; lines 1205 and 1301 `Dir.openFileAbsolute(io, test_file, .{})` in tests.

Every `defer file.close()` becomes `defer file.close(io)`, and every `defer dir.close()` becomes `defer dir.close(io)`.

The two test sites need their own `io`; add the `std.Io.Threaded` setup from Task 7 Step 6 to each.

- [ ] **Step 3: Convert `src/logging.zig`**

Line 133 `Dir.createFileAbsolute(io, active_path, .{ ... })` — keep the existing flags struct verbatim. Line 166 `Dir.renameAbsolute(active_path, archive_path, io)` — **`io` goes last here**, unlike every other call in this table. Line 274 `Dir.cwd().createDirPath(io, raw_directory_path)`. Line 275 `Dir.cwd().realPathFileAlloc(io, raw_directory_path, allocator)` — note the argument order differs from 0.15's `realpathAlloc(allocator, path)`. Line 387 `Dir.openFileAbsolute(io, active_path, .{})`. Lines 483 and 524 `Dir.openDirAbsolute(io, ..., .{ .iterate = true })`, and their iterator loops become `while (try it.next(io)) |entry|`. Lines 507 and 510 `Dir.cwd().deleteTree(io, relative_dir)`. The `file: ?fs.File` field at line 23 becomes `file: ?File`, and the `openActiveLogFile` return type at line 130 becomes `!struct { file: File, size: u64 }`.

`LoggerState` is shared across threads behind a mutex, so it must store `io` as a field rather than receive it per call — the log functions are called from `std.log`'s handler, which has no place to pass one.

- [ ] **Step 4: Convert `src/mcp/main.zig`**

Task 7 already changed `main`, `run`, and the `stdin`/`stdout` types. The remaining work is the read loop and the writes. `File.read` is gone:

```zig
        const n = try stdin_file.readStreaming(io, &.{&chunk});
```

and every `stdout_file.writeAll(bytes)` becomes:

```zig
        try stdout_file.writeStreamingAll(io, bytes);
```

Thread `io` into `handleMessage` and `writeJsonRpcError` alongside their existing `allocator` parameters.

- [ ] **Step 5: Convert `src/shell.zig`**

Sixteen sites, all `std.fs.`-qualified so grep finds them: `std.fs.makeDirAbsolute` becomes `std.Io.Dir.createDirAbsolute(io, path, .default_dir)` at lines 674, 685, 694, 705, 786, 800, 850; `std.fs.createFileAbsolute` becomes `std.Io.Dir.createFileAbsolute(io, path, flags)` at lines 717, 813, 1176. Keep every existing `catch |err| switch (err)` block exactly as-is — the error sets are compatible. Run `grep -n 'std\.fs\.' src/shell.zig` after editing and convert whatever remains that is not `std.fs.path.*` or `std.fs.max_path_bytes`.

- [ ] **Step 6: Convert `src/font_paths.zig` and `src/app/control.zig`**

Six and five sites respectively, all `std.fs.`-qualified. Apply the mapping table. `src/app/control.zig` is compiled into both the main binary and the `control` module for `architect-mcp`, so its `io` must arrive as a parameter or stored field, never from `src/main.zig`.

- [ ] **Step 7: Verify no filesystem call remains in these six files**

Run: `for f in src/shell.zig src/config.zig src/mcp/main.zig src/logging.zig src/font_paths.zig src/app/control.zig; do echo "== $f"; grep -nE '\b(std\.)?fs\.[A-Za-z_]+' "$f" | grep -vE 'fs\.(path|max_path_bytes|max_name_bytes)'; done`
Expected: no lines under any file heading.

- [ ] **Step 8: Verify the error class shrank**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -nE 'src/(shell|config|logging|font_paths|mcp/main|app/control)\.zig' .tmp/flip-errors.txt | grep -vE 'Mutex|Condition'`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: move core filesystem calls to std.Io.Dir and std.Io.File"
```

---

## Step 11: Convert the filesystem calls in the UI components

The remaining 19 source sites.

**Files:**
- Modify: `src/ui/components/pr_dropdown_repo.zig` (9 sites), `src/ui/components/worktree_overlay.zig` (4), `src/ui/components/diff_overlay.zig` (4), `src/ui/components/story_overlay.zig` (1), `src/app/runtime.zig` (1)

**Interfaces:**
- Consumes: `io` threaded in by Tasks 8 and 9
- Produces: no `fs.` filesystem calls remain anywhere in `src/`

- [ ] **Step 1: Convert each file using the mapping table**

All sites in these files use the `std.fs.`-qualified spelling, so `grep -n 'std\.fs\.' <file>` enumerates them. Use `self.io` inside component methods (Task 9 added the field) and the function's `io` parameter in free functions.

- [ ] **Step 2: Verify no filesystem call remains anywhere**

Run: `grep -rnE '\b(std\.)?fs\.[A-Za-z_]+' src build.zig | grep -vE 'fs\.(path|max_path_bytes|max_name_bytes)'`
Expected: no output.

Run: `grep -rn 'std\.fs\.File\|std\.fs\.Dir' src build.zig`
Expected: no output.

- [ ] **Step 3: Verify the error class shrank**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`

Run: `grep -cE 'Mutex|Condition' .tmp/flip-errors.txt`
Expected: the only remaining errors are mutex and condition errors, so this count equals the total error count from `grep -c 'error:'`.

- [ ] **Step 4: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor(ui): move component filesystem calls to std.Io.Dir"
```

---

## Step 12: Convert the mutexes and condition variables

**Files:**
- Modify: `src/logging.zig:19`, `src/ui/components/pr_dropdown.zig:25`, `src/app/control.zig:92`, `src/app/control.zig:93`, `src/app/control.zig:123`, `src/session/notify.zig:25`, `src/session/pty_reader.zig:44`, `src/session/pty_reader.zig:173`

**Interfaces:**
- Consumes: `io` available as a field on every struct that owns a mutex (Tasks 8 and 9)
- Produces: no `std.Thread.Mutex` or `std.Thread.Condition` remains. `SpawnCompletion.complete(io, response)` and `SpawnCompletion.wait(io)` gain an `io` parameter, so their callers in `src/app/control.zig` and `src/app/runtime.zig` must pass one.

- [ ] **Step 1: Change the declarations**

`std.Io.Mutex` and `std.Io.Condition` initialize with `.init`, not `.{}` — a default-initialized `.{}` will not compile because both carry non-defaulted atomic state. For each of the eight declarations:

```zig
    mutex: std.Io.Mutex = .init,
```

```zig
    condition: std.Io.Condition = .init,
```

- [ ] **Step 2: Add `io` to every lock, unlock, and wait**

Use the uncancelable variants. `Io.Mutex.lock` and `Io.Condition.wait` return `Cancelable!void`, and Architect never requests cancellation, so making every lock site fallible would add `catch` blocks with no correct recovery — which `CLAUDE.md`'s error-handling rule forbids resolving with a bare `catch`. `lockUncancelable` and `waitUncancelable` are total functions.

`src/app/control.zig`'s `SpawnCompletion` becomes:

```zig
pub const SpawnCompletion = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: bool = false,
    response: SpawnResponse = undefined,

    pub fn complete(self: *SpawnCompletion, io: std.Io, response: SpawnResponse) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.response = response;
        self.completed = true;
        self.condition.signal(io);
    }

    pub fn wait(self: *SpawnCompletion, io: std.Io) SpawnResponse {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (!self.completed) {
            self.condition.waitUncancelable(io, &self.mutex);
        }
        return self.response;
    }
};
```

`std.Io.Condition.signal(io)` and `broadcast(io)` both take `io` (verified at `lib/std/Io.zig:1726` and `:1745`), so every signal site needs it too — not just the waits.

Apply the same pattern to `SpawnQueue` (`src/app/control.zig:123`), `LoggerState` (`src/logging.zig:19`), the PR dropdown (`src/ui/components/pr_dropdown.zig:25`), the notify handler (`src/session/notify.zig:25`), and both `src/session/pty_reader.zig` mutexes (lines 44 and 173).

`src/session/pty_reader.zig`'s mutexes are on the hot path between the PTY reader thread and the frame loop, so keep the critical sections exactly as narrow as they are today — do not widen a `defer unlock` to cover more work than the original.

- [ ] **Step 3: Verify no thread synchronization primitive remains**

Run: `grep -rn 'std\.Thread\.\(Mutex\|Condition\)' src`
Expected: no output.

Run: `grep -rn '\.lock()\|\.unlock()\|\.wait(&' src`
Expected: no output — every call now takes `io`.

- [ ] **Step 4: Commit**

```bash
nix develop --command zig fmt src/
git add src/
git commit -m "refactor: move synchronization to std.Io.Mutex and std.Io.Condition

Lock sites use the uncancelable variants: Architect has no cancellation
model, so a fallible lock would add error paths with no correct recovery."
```

---

## Step 13: Reach a green build, tests, and lint

This is the first task in the flip whose gate is a fully green build.

**Files:**
- Modify: whatever the remaining diagnostics name

**Interfaces:**
- Consumes: everything from Tasks 6–12
- Produces: `zig build`, `zig build test`, and `just lint` all green under Zig 0.16.0

- [ ] **Step 1: Drive the remaining errors to zero**

Run: `nix develop --command bash -c 'zig build 2>&1 | tee .tmp/flip-errors.txt' || true`
Run: `grep -c 'error:' .tmp/flip-errors.txt`

Fix each remaining diagnostic. Expect a residue of items no earlier task enumerated: `std.Io.Writer` drift at the 12 pre-existing `std.Io.*` sites (Risk 5 in the spec), `std.posix` helpers that moved, and integer-width mismatches where `i96` meets `i128`. For each, read the real signature in the installed 0.16 lib directory before editing:

```bash
nix develop --command bash -c 'echo "$(dirname "$(readlink -f "$(which zig)")")/../lib/std"'
```

Never guess an API shape. If a diagnostic is not obviously mechanical, stop and report it rather than inventing a workaround.

- [ ] **Step 2: Normalize the deprecated ArrayList alias**

0.16 keeps `std.ArrayListUnmanaged` as a deprecated alias for `std.ArrayList`, so these four sites compile but should not stay. `CLAUDE.md` mandates the `std.ArrayList` spelling:

Run: `grep -rn 'ArrayListUnmanaged' src`
Expected before: `src/config.zig`, `src/app/control.zig`, `src/session/state.zig`, `src/session/notify.zig`.

Replace each `std.ArrayListUnmanaged(T)` with `std.ArrayList(T)`. The type is identical, so no other change is needed.

Run: `grep -rn 'ArrayListUnmanaged' src`
Expected after: no output.

- [ ] **Step 3: Verify the build**

Run: `nix develop --command zig build`
Expected: exit 0.

- [ ] **Step 4: Verify the tests**

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped — a pipe would mask a failing exit code.

If any test fails, fix it. Do not weaken or delete a test to get green; a test that now fails is either a migration defect or a test that encoded a 0.15 implementation detail, and the two need different responses. If it is the latter, say so explicitly in the commit message.

- [ ] **Step 5: Verify the test registry**

Run: `nix develop --command ./scripts/check-test-registry.sh`
Expected: exit 0. `src/env.zig`, `src/clock.zig`, and `src/proc.zig` were registered in Tasks 3–5; this confirms nothing regressed.

- [ ] **Step 6: Verify lint, including Zwanzig under 0.16**

Run: `nix develop --command just lint`
Expected: exit 0. This is also the live confirmation that zwanzig v0.15.1 builds and runs under Zig 0.16.0 — the `zig build lint` step compiles it from source with the host toolchain.

If zwanzig fails to compile here, its `src/compat.zig` gate is the place to look; report the diagnostics rather than patching around them.

- [ ] **Step 7: Commit the formatting churn separately**

0.16's `zig fmt` may reformat files that 0.15.2 formatted differently. Keep it out of the substantive commits:

```bash
nix develop --command zig fmt src/
git add -A src/
git commit -m "style: apply zig 0.16 formatting"
```

If this produces an empty commit, skip it.

- [ ] **Step 8: Verify formatting is stable**

Run: `nix develop --command zig fmt --check src/`
Expected: exit 0, no output.

---

## Step 14: Resolve the macOS SDK workaround

**Files:**
- Modify: `flake.nix:81-84`, and possibly delete `scripts/setup-macos-sdk-workaround.sh`

**Interfaces:**
- Consumes: the Task 1 Step 9 conclusion
- Produces: either a removed workaround or an updated comment naming 0.16.0

- [ ] **Step 1: Read the Task 1 conclusion**

Open `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md` and find the SDK-workaround verdict. Do not re-derive it.

- [ ] **Step 2a: If Task 1 concluded the workaround is unnecessary — remove it**

Delete these lines from `flake.nix`:

```nix
            # Zig 0.15.2 cannot link correctly against the arm64e-only macOS 26.4 SDK stubs.
            # Remove this once we move off Zig 0.15.2 or the upstream fix lands.
            project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            . "$project_root/scripts/setup-macos-sdk-workaround.sh"
```

Then check whether anything else references the script:

Run: `grep -rn 'setup-macos-sdk-workaround' . --exclude-dir=.git --exclude-dir=.tmp --exclude-dir=zig-out`
Expected: only `scripts/setup-macos-sdk-workaround.sh` itself and any docs mentioning it.

If nothing else references it, delete the script and remove the repo note about it from `CLAUDE.md` (Task 15 covers the doc edit). If the release workflow references it, leave the script and stop — that is a separate change.

- [ ] **Step 2b: If Task 1 concluded the workaround is still needed — update its comment**

```nix
            # Zig 0.16.0 cannot link correctly against the arm64e-only macOS 26.4 SDK stubs.
            # Remove this once the upstream fix lands.
            project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            . "$project_root/scripts/setup-macos-sdk-workaround.sh"
```

- [ ] **Step 3: Verify the shell still builds the project**

Run: `nix develop --command zig build`
Expected: exit 0.

Run: `nix develop --command zig build test`
Expected: exit 0. Run this unpiped.

If removal broke linking, the Task 1 conclusion was wrong for this host. Restore the workaround, take branch 2b instead, and record the discrepancy in the inventory doc.

- [ ] **Step 4: Verify the release build path**

Run: `nix develop --command zig build -Doptimize=ReleaseFast`
Expected: exit 0. Release builds use a different link configuration than Debug, and the SDK workaround affects linking specifically.

- [ ] **Step 5: Commit**

```bash
git add flake.nix scripts/ 2>/dev/null
git commit -m "build: resolve the macOS SDK workaround for Zig 0.16.0"
```

---

## Step 15: Update the documentation and verify the app by hand

`CLAUDE.md` requires documentation updates in the same change as the code. This task also carries the manual verification that no automated check can reach, because Architect is an SDL3 application.

**Files:**
- Modify: `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/development.md`, `README.md` (conditional), `docs/perf-debugging.md` (conditional)

**Interfaces:**
- Consumes: the completed migration
- Produces: documentation consistent with the 0.16 codebase

- [ ] **Step 1: Update `CLAUDE.md`**

`AGENTS.md` is a symlink to `CLAUDE.md`, so edit only `CLAUDE.md`.

Change the stack line:

```markdown
**Stack:** Zig 0.16, SDL3, ghostty-vt (terminal emulation), Nix dev shell, `just` task runner
```

Replace the `### Zig 0.15 collection API differences` section heading and its now-wrong contents. The `std.ArrayList` guidance still holds in 0.16 and should stay; the `std.fmt.allocPrintZ` and writer notes should be re-verified against 0.16 before being kept. Add the migration's own hard-won gotchas:

```markdown
### Zig 0.16 API notes
- `std.ArrayList(T)` is the unmanaged list: init with `.empty` (or `initCapacity`), and pass the allocator to each method (`list.append(allocator, item)`). `std.ArrayListUnmanaged` is a deprecated alias — do not use it.
- `std.fs` retains only `path`, `max_path_bytes`, `max_name_bytes`, and the base64 alphabets. Every filesystem operation moved to `std.Io.Dir` / `std.Io.File` and takes an `io` argument. Two irregularities to remember: `Dir.renameAbsolute(old, new, io)` takes `io` **last**, and `makeDirAbsolute`/`makePath` were renamed to `createDirAbsolute`/`createDirPath` rather than merely gaining a parameter.
- `std.time` retains only its duration constants. Timestamps come from `clock.zig`, which wraps `std.Io.Timestamp.now(io, .real)`. The clock enum tags are `real`, `awake`, `boot`, `cpu_process`, `cpu_thread`.
- `std.Thread.spawn`/`join`/`detach` survive; `std.Thread.Mutex`, `Condition`, `Pool`, `WaitGroup`, and `sleep` do not. Use `std.Io.Mutex` / `std.Io.Condition`, initialized with `.init` (not `.{}`), and prefer `lockUncancelable`/`waitUncancelable` — Architect has no cancellation model, so a fallible lock adds error paths with no correct recovery.
- `std.process.Child` keeps only `kill(io)` and `wait(io)`. Creation is `std.process.spawn(io, opts)`; the collect-output pattern is `std.process.run(gpa, io, opts)`. `Child.Term` tags are lowercase (`.exited`, `.signal`, `.stopped`, `.unknown`) and `signal` carries `std.posix.SIG`, not `u32`.
- Link and include configuration lives on `std.Build.Module`, not `std.Build.Step.Compile`. `link_libc` is a Module field, settable in `b.createModule`.
- `std.posix.getenv` is gone. Read the environment through `src/env.zig`.

### Inventory greps for std API migrations
`const fs = std.fs;` and `const posix = std.posix;` aliases hide call sites from a `std.`-qualified grep — this cost real time during the 0.16 migration. Always match `\b(std\.)?fs\.` and `\b(std\.)?posix\.`. When excluding survivors, put the underscore in the character class: `fs\.[A-Za-z]+` truncates `fs.max_path_bytes` to `fs.max` and lets it slip past the filter.
```

Add to the Architecture Invariants section:

```markdown
- `io: std.Io` is threaded explicitly, as a struct field immediately after `allocator` or a parameter immediately after `allocator`. Never store it in a module-level variable. Structs whose threads outlive the spawner must store their own copy.
- `src/env.zig` is the only sanctioned module-level accessor in the codebase, because `std.Io` exposes no environment surface and the process environment is global and immutable. Do not add others.
```

Update the repo note about the macOS SDK workaround to match whatever Task 14 concluded.

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`**

Document the three new shared-utility modules alongside the existing `src/geom.zig` / `src/anim/easing.zig` / `src/gfx/primitives.zig` tier, and the `io` carrier data flow from `main(init)` through `runtime.run` into the session and UI layers. Read the existing document's structure first and follow it rather than appending a new section at the end.

- [ ] **Step 3: Update `docs/development.md`**

Update the Zig version and any setup instructions that name 0.15.2.

- [ ] **Step 4: Check `README.md` and `docs/perf-debugging.md`**

Run: `grep -n '0\.15' README.md docs/perf-debugging.md docs/configuration.md docs/ai-integration.md`

Update every hit. If there are none, leave the files alone — do not edit them to look busy.

- [ ] **Step 5: Verify no stale version references remain**

Run: `grep -rn '0\.15\.2\|Zig 0\.15' --exclude-dir=.git --exclude-dir=.tmp --exclude-dir=zig-out --exclude-dir=.zig-cache .`
Expected: only `docs/superpowers/specs/2026-08-28-zig-0-16-migration-design.md`, `docs/superpowers/plans/2026-08-28-zig-0-16-migration.md`, and `docs/superpowers/plans/2026-08-28-zig-0-16-inventory.md`, which document the migration and should retain their historical references.

- [ ] **Step 6: Verify the whole pipeline**

Run: `nix develop --command just ci`
Expected: exit 0. This runs build, test, and lint in sequence.

- [ ] **Step 7: Verify the app by hand**

Automated checks cannot reach any of Architect's rendering, terminal, or subprocess behavior. Run `nix develop --command zig build run` and confirm every item:

- The window opens and the terminal grid renders; typing echoes correctly.
- Resizing the window reflows the terminals without corruption.
- Spawning a new session works; killing a shell shows the restart button; restart works.
- Config loads from `~/.config/architect/config.toml` without a `HomeNotFound` error, and editing it triggers a reload.
- Terminal cwd persistence works: change directory in a session, quit, relaunch, and confirm the session restores into that directory (macOS only).
- The log file under the log directory has correct ISO-8601 timestamps, and log rotation produces correctly named archives — this is the only exercise of `logging.zig`'s `renameAbsolute`, whose `io`-last signature is the easiest thing in this migration to get wrong.
- Layout expand/collapse animation runs smoothly.
- ⌘O (recent folders), ⌘T, and ⌘? overlays open, and the collapsed `⌘O`/`⌘T`/`⌘?` badges render.
- ⌘P opens the PR dropdown and populates from `gh` in a repo with open pull requests; with `gh` removed from `PATH` it shows the "gh not found" state.
- The diff overlay opens, renders a diff, and comment annotation works.
- The worktree overlay opens and abbreviates paths under home with `~`.
- Clicking a URL in terminal output opens the browser.
- The control socket works: run `architect story <some-file.md>` and confirm the story overlay appears.
- `architect-mcp` responds: pipe a JSON-RPC `initialize` request to it on stdin and confirm a well-formed response on stdout. This is the only exercise of `mcp/main.zig`'s converted read and write loop.
- Quitting with a busy session shows the shimmer overlay for its normal duration and then exits.

Record any discrepancy as a migration defect and fix it before proceeding.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "docs: update documentation for Zig 0.16.0"
```

- [ ] **Step 9: Open the flip PR**

Use the `managing-github` skill. The PR body must follow the structure in the global `CLAUDE.md`: Issue, Solution, Context, Test plan. The Test plan is the checklist from Step 7 — the reviewer needs to repeat it, since none of it is covered by CI.
