# Design: Migrate Architect to Zig 0.16.0

**Date:** 2026-08-28
**Status:** Approved design; implementation plan pending

## Goal

Move Architect from Zig 0.15.2 to Zig 0.16.0 as a hard cutover, with no
dual-toolchain support in Architect's own source. Land as much of the change as
possible on 0.15.2 first so the irreversible flip is a small, reviewable diff.

## Non-goals

- Supporting both 0.15.2 and 0.16.0 from one source tree. Zwanzig needs that
  because it *embeds* `std.zig` and must analyze projects on both language
  versions; Architect is a leaf application with no such constraint.
- Restructuring Architect's threading model. `std.Thread.spawn`/`join`/`detach`
  survive in 0.16, so the seven spawn sites and the libxev-based main loop stay.
- Adopting `std.Io` async primitives (`Io.Group`, `Io.async`, `Io.Threaded`
  task APIs). Architect gets an `Io` instance only because 0.16 requires one to
  call filesystem, clock, sleep, mutex, and subprocess APIs.
- Any behavior change. Every observable behavior must be identical after the
  migration.

## Verified findings

Every claim below was verified on 2026-08-28 against the `0.16.0` tag of
`ziglang/zig` on Codeberg (`https://codeberg.org/ziglang/zig`, which carries the
`0.16.0` tag; the GitHub mirror stops at `0.15.2`), against the locally
installed Zig 0.15.2 (`nix` store `zig-0.15.2/lib/std`), and against this
repository at `fc533ee`.

### Corrections to the pre-design investigation

Two claims from the earlier investigation do not hold and materially reduce
scope:

1. **`std.ArrayList` requires no work.** `lib/std/std.zig:49` defines
   `pub fn ArrayList(comptime T: type) type` as the *unmanaged* list;
   `lib/std/std.zig:59` marks `ArrayListUnmanaged` as the deprecated alias, and
   `lib/std/array_list.zig:11` exposes the managed variant as
   `array_list.Managed`. This is the same shape as 0.15.2. Architect's 129
   `std.ArrayList` references already use `.empty` plus allocator-per-method
   (mandated by `CLAUDE.md`), so the estimated "~110 references" of migration
   work is zero.
2. **The blast radius is 20 of 89 source files, not 89.** Of 178 `fs.`
   references in `src/` plus `build.zig` (counting both the `std.fs.` spelling
   and the `const fs = std.fs;` aliases in `src/config.zig`, `src/logging.zig`,
   and `src/session/state.zig`), 93 are `fs.path.*`, `fs.max_path_bytes`, or
   `fs.max_name_bytes`, all of which survive (`lib/std/fs.zig` in 0.16 is 21
   lines and retains exactly `path`, the base64 alphabets, `max_path_bytes`, and
   `max_name_bytes`). The remaining 85 real filesystem sites live in 11 source
   files plus `build.zig`.

   The same aliasing applies to `const posix = std.posix;`, which hides 11 of
   the 23 `getenv` sites. Any inventory grep for this migration must match
   `\b(std\.)?fs\.` and `\b(std\.)?posix\.`, not just the `std.`-qualified
   spelling, and must exclude `max_path_bytes` with the trailing underscore in
   the character class — `fs\.[A-Za-z]+` truncates it to `fs.max` and lets it
   through.

### Breaking-change inventory

| Concern | 0.16 replacement | Sites | Files |
| --- | --- | --- | --- |
| `std.fs.{openFileAbsolute,openDirAbsolute,makeDirAbsolute,createFileAbsolute,accessAbsolute,deleteFileAbsolute,renameAbsolute,cwd,File,Dir}` | `std.Io.Dir` / `std.Io.File`, each taking `io` | 84 | 11 |
| `std.posix.getenv` (removed) | `std.process.Environ.getPosix`; `b.graph.environ_map` in build scripts | 23 + 4 in `build.zig` | 11 + build.zig |
| `std.time.timestamp` / `milliTimestamp` / `nanoTimestamp` (removed) | `std.Io.Timestamp.now(io, clock)` / `std.Io.Clock` | 13 | 6 |
| `std.Thread.sleep` (removed) | `std.Io.sleep(io, duration, clock)` | 14 | 6 |
| `std.process.Child.init` / `Child.run` | `std.process.spawn(io, opts)` / `std.process.run(gpa, io, opts)` | 7 + 1 in `build.zig` | 6 + build.zig |
| `std.Thread.Mutex` / `std.Thread.Condition` (removed) | `std.Io.Mutex` / `std.Io.Condition`; `lock`/`unlock`/`wait` all take `io` | 8 | 5 |
| `std.heap.GeneralPurposeAllocator` (removed) | `std.heap.DebugAllocator` | 2 | 2 |
| `Compile.linkSystemLibrary` / `linkLibC` / `linkFramework` / `addIncludePath` / `addLibraryPath` / `addFrameworkPath` (removed) | the same methods on `std.Build.Module`; `link_libc` is a Module field | 11 | build.zig |
| **Union of source files needing edits** | | **~151** | **20 of 89** |

The 20 files: `src/app/control.zig`, `src/app/layout.zig`, `src/app/runtime.zig`,
`src/app/worktree.zig`, `src/config.zig`, `src/font_paths.zig`,
`src/logging.zig`, `src/mcp/main.zig`, `src/os/open.zig`,
`src/session/notify.zig`, `src/session/pty_reader.zig`, `src/session/state.zig`,
`src/shell.zig`, `src/ui/components/diff_overlay.zig`,
`src/ui/components/pr_dropdown.zig`, `src/ui/components/pr_dropdown_fetch.zig`,
`src/ui/components/pr_dropdown_repo.zig`,
`src/ui/components/recent_folders_overlay.zig`,
`src/ui/components/story_overlay.zig`,
`src/ui/components/worktree_overlay.zig`.

Filesystem sites are concentrated: `src/shell.zig` (16), `src/config.zig` (14),
`src/mcp/main.zig` (13), `src/logging.zig` (11),
`src/ui/components/pr_dropdown_repo.zig` (9), `src/font_paths.zig` (6),
`src/app/control.zig` (5), `src/ui/components/worktree_overlay.zig` (4),
`src/ui/components/diff_overlay.zig` (4), `src/ui/components/story_overlay.zig`
(1), `src/app/runtime.zig` (1), and `build.zig` (1).

### Things that do not change

- `std.Thread.spawn`, `join`, `detach`, `getCpuCount`, `SpawnConfig` all remain
  in `lib/std/Thread.zig` (0.16 `Thread.zig:344`, `:364`, `:370`, `:293`, `:298`).
  `std.Thread.setName` gains an `io` parameter but Architect does not call it.
- `std.time.ns_per_ms` and the other duration constants remain
  (`lib/std/time.zig`); all 25 Architect uses are unaffected.
- `std.debug.print` remains (`lib/std/debug.zig:307`).
- `std.fs.path.*` and `std.fs.max_path_bytes` remain.
- `@cImport` remains a valid builtin in 0.16 (`lib/std/zig.zig` still emits
  `operand_cImport` AstGen diagnostics), so `src/c.zig` keeps its shape. See
  Risk 1 for the translate-c caveat.
- A zero-parameter `pub fn main()` is still accepted (`lib/std/start.zig:698`).
  Taking `std.process.Init` is opt-in, and Architect opts in.
- Zwanzig needs no version bump. `zwanzig` v0.15.1's `src/compat.zig:11` gates
  `supported_zig_versions = {0.15.2, 0.16.0}` and its CI
  (`.github/workflows/build.yml:64`) builds both frontends, so the ReleaseFast
  linter artifact Architect builds at `build.zig:133` compiles under 0.16.

### Prep-phase feasibility, verified on the installed 0.15.2

- `std.Build.Module.linkSystemLibrary`, `linkFramework`, `addIncludePath`,
  `addFrameworkPath`, and `addLibraryPath` all exist in 0.15.2
  (`Build/Module.zig:363`, `:392`, `:485`, `:501`, `:512`) as well as in 0.16.
  `Compile` still carries the deprecated spellings in 0.15.2
  (`Build/Step/Compile.zig:685`, `:810`, `:826`), so the move is a pure
  no-behavior-change refactor that today's toolchain compiles.
- `std.heap.DebugAllocator` exists in 0.15.2 (`heap.zig:21`), where
  `GeneralPurposeAllocator` is merely an alias for it (`heap.zig:26`).
- `headerpad_max_install_names` remains a `Compile` field in 0.16
  (`Build/Step/Compile.zig:162`), so `build.zig`'s macOS handling is unaffected
  by the Module move.

## Dependency graph

| Dependency | Current | Target | Basis |
| --- | --- | --- | --- |
| `ghostty` | `v1.3.1` tag | `main` @ `76e568b475fe88f5506be33ad1a684f3c1eae85e` (`1.3.2-dev`) | no `v1.3.2` tag exists; `main`'s `build.zig.zon` declares `minimum_zig_version = "0.16.0"`; `src/build/GhosttyZig.zig:117` still calls `b.addModule("ghostty-vt", ...)`, so Architect's `dep.module("ghostty-vt")` import survives |
| `libxev` | `34fa50878aec6e5fa8f532867001ab3c36fae23e` | `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, hash `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` | ghostty `main` pins this commit, and its `build.zig.zon` declares `minimum_zig_version = "0.16.0"`. Architect's current pin matches ghostty v1.3.1's, and staying aligned should continue |
| `toml` | `cf50bd59c6276fb2b6d34b8d71d35486eecc719c` (main) | `8685923e32e8b8a795eb2715684236975a70faed` (`zig-0.16` branch head, 2026-06-11, "Adjust CI for zig 0.16") | upstream `sam701/zig-toml` maintains per-Zig-version branches and has not tagged the 0.16 line |
| `zwanzig` | `v0.15.1` | unchanged | already supports 0.16.0 (see above) |

`ghostty-vt` does not import `xev` (`src/build/GhosttyZig.zig` gives it only
`unicode_tables`, `uucode`, `wuffs`, and `build_options`), so Architect's
`libxev` pin is independent of ghostty's. Keeping them equal remains the
convention, not a hard requirement.

Re-pin ghostty to the `v1.3.2` tag once upstream releases it. That is follow-up
work, not part of this migration.

## Architecture

### `Io` propagation: explicit

`io: std.Io` travels the same paths `allocator` already travels: as a struct
field beside the existing `allocator` field (104 structs declare one), or as a
parameter beside the existing `allocator` parameter (261 occurrences of
`allocator: std.mem.Allocator`, of which the 104 above are struct fields,
leaving roughly 157 parameters).
No process-wide `Io` accessor. `std.Io` is a fat pointer (vtable plus context),
so copying it into structs is cheap.

```zig
pub const SessionState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // ...
};

fn loadConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // ...
}
```

### Entry points take `std.process.Init`

`src/main.zig:14` and `src/mcp/main.zig:18` become
`pub fn main(init: std.process.Init) !void`. `std.process.Init` supplies
`io`, `gpa`, `arena`, and `environ_map` (0.16 `lib/std/process.zig:30`), which
simultaneously removes both `GeneralPurposeAllocator` sites
(`src/app/runtime.zig:1410`, `src/mcp/main.zig:19`) and gives `src/env.zig` its
backing `Environ`.

### `src/env.zig`: the one deliberate module-level accessor

`std.Io` exposes no environment access; `lib/std/Io.zig` contains zero
`environ`/`Environ` references, and the only `Io`-adjacent accessor,
`Io.Threaded.environString` (`Io/Threaded.zig:16925`), is implementation-specific
and therefore not usable through the `Io` interface.

Threading `std.process.Environ` as a second context through eleven files would
double the plumbing for data that is process-global and immutable. `src/env.zig`
therefore holds the process `Environ`, initialized exactly once in `main` before
any thread is spawned, and exposes:

```zig
pub fn init(environ: std.process.Environ) void;
pub fn get(key: []const u8) ?[:0]const u8;   // wraps Environ.getPosix
```

This preserves the semantics of `std.posix.getenv` exactly — that function was
itself a global accessor over the same immutable process input — so it is a
non-regression rather than a newly introduced global. It is the *only* sanctioned
module-level accessor in this migration; `io` is never stored this way.

`build.zig`'s four `std.posix.getenv` calls (`build.zig:91`, `:96`, `:151`,
`:178`) use `b.graph.environ_map.get` instead
(0.16 `lib/std/Build.zig:121`), and `build.zig`'s subprocess and filesystem calls
use `b.graph.io` (`lib/std/Build.zig:113`).

### `src/clock.zig` and `src/proc.zig`

Two thin wrappers, introduced during prep with 0.15 internals and re-implemented
during the flip:

- `src/clock.zig` — wraps the 13 timestamp sites. Exposes millisecond and
  nanosecond readings and the wall-clock seconds that `src/logging.zig:153` and
  `:197` need for ISO-8601 formatting. Backed by `std.Io.Timestamp.now(io, clock)`
  on 0.16 (`lib/std/Io.zig:909`, `Io.Clock` at `:721`).
- `src/proc.zig` — wraps the 7 `std.process.Child` sites, becoming
  `std.process.run(gpa, io, opts)` / `std.process.spawn(io, opts)` on 0.16
  (`lib/std/process.zig:496`, `:442`).

Both take `io` explicitly. Their purpose is to collapse ~20 scattered call sites
into two files so the flip diff shrinks; they are permanent modules, not
migration scaffolding, and they belong to the shared-utility tier alongside
`src/geom.zig` and `src/gfx/primitives.zig`.

Filesystem calls get **no** wrapper module. The 84 sites are spread across only
11 files and their argument shapes vary too much for a wrapper to pay for itself;
they are rewritten in place to `std.Io.Dir`/`std.Io.File` during the flip.

### Synchronization

The eight `std.Thread.Mutex` / `std.Thread.Condition` declarations
(`src/logging.zig:19`, `src/ui/components/pr_dropdown.zig:25`,
`src/app/control.zig:92`, `:93`, `:123`, `src/session/notify.zig:25`,
`src/session/pty_reader.zig:44`, `:173`) become `std.Io.Mutex` /
`std.Io.Condition`, initialized with `.init` rather than `.{}`
(0.16 `lib/std/Io.zig:1590`, `:1663`). Every `lock`/`unlock`/`wait` call gains
`io`.

`Io.Mutex.lock` and `Io.Condition.wait` return `Cancelable!void`. Architect has
no cancellation model, so lock sites use `lockUncancelable` /
`waitUncancelable` (`lib/std/Io.zig:1623`, `:1675`), which are total functions
and therefore introduce no `catch` sites and no new error paths. This choice is
deliberate: making lock acquisition fallible everywhere would add error handling
that has no correct recovery, which `CLAUDE.md`'s error-handling rule forbids
resolving with a bare `catch`.

### Toolchain and environment

- `flake.nix:49`: `zig.packages.${system}."0.15.2"` becomes `"0.16.0"`.
- `build.zig.zon:5`: `.minimum_zig_version = "0.15.2"` becomes `"0.16.0"`.
- CI needs no version edit: `.github/workflows/build.yml` invokes everything
  through `nix develop --accept-flake-config --command just ...`, so `flake.nix`
  is the single source of truth.
- `just setup` reads only the first `.url` in `build.zig.zon`, which remains
  ghostty's, so it keeps working after the pin changes.
- The macOS arm64e SDK workaround (`flake.nix:81-84` plus
  `scripts/setup-macos-sdk-workaround.sh`) gets a removal *attempt*: Zwanzig's
  0.16 spike on `aarch64-darwin` linked successfully without it. If the 0.16
  linker still fails against the arm64e-only `MacOSX.sdk` stubs, the workaround
  stays and its comment is updated to name 0.16.0 instead of 0.15.2. Removal is
  not a precondition for the flip.

## Sequencing

Three prep changes land on `main` against Zig 0.15.2, each independently
CI-green. The toolchain flip is then a single atomic change, because Architect
cannot build on both toolchains at once: ghostty `1.3.2-dev` requires 0.16.0,
and 0.16.0 removes `std.fs`'s and `std.time`'s operational APIs outright.

Risks 1 through 3 below are verified before any prep change is written, since a
failure there invalidates the whole approach rather than one step of it.

**Prep 1 — `build.zig` module-based linking.** Move `linkSystemLibrary`,
`linkLibC`, `linkFramework`, `addIncludePath`, `addLibraryPath`, and
`addFrameworkPath` from `exe`/`mcp_exe` onto `exe_mod`/`mcp_mod`. Replace the
four `std.posix.getenv` calls with `b.graph.environ_map.get`. Verifiable in full
on 0.15.2.

**Prep 2 — allocator and environment.** `GeneralPurposeAllocator` becomes
`DebugAllocator` at `src/app/runtime.zig:1410` and `src/mcp/main.zig:19`.
Introduce `src/env.zig` with a 0.15 internal (`std.posix.getenv`) and route all
23 call sites through it.

**Prep 3 — `src/clock.zig` and `src/proc.zig`.** Introduce both with 0.15
internals and move the 13 timestamp and 7 subprocess sites onto them.

**Threading the `io` carrier is not a prep change.** It would require passing a
placeholder `io` that 0.15 has no type for, so it folds into the flip.

**Flip — one change.** `flake.nix` and `build.zig.zon` (toolchain plus the three
dependency pins, hashes regenerated with `zig fetch` under 0.16); entry points
take `std.process.Init`; `io` threaded through structs and signatures;
`env.zig`, `clock.zig`, and `proc.zig` internals rewritten; the 84 filesystem
sites rewritten; the 8 synchronization primitives and 14 sleeps converted; the
SDK-workaround removal attempt.

## Testing and verification

- Each prep change and the flip must leave `zig build`, `zig build test`, and
  `just lint` green. `zig build test` is run **unpiped** in the call whose exit
  code decides success; piping masks failures.
- `zig fmt` from 0.16 will reformat files that 0.15.2 formatted differently.
  That reformatting goes in its own commit inside the flip change so the
  substantive diff stays reviewable.
- New modules (`src/env.zig`, `src/clock.zig`, `src/proc.zig`) that declare
  tests must be registered in `src/main.zig`'s `test { _ = @import(...); }`
  block; `scripts/check-test-registry.sh` (part of `just lint`) enforces this.
- Behavior coverage that automation cannot reach, because Architect is an SDL3
  application, requires the developer: launch the app; spawn and restart
  sessions; verify PTY output and resize; open the diff overlay, worktree
  overlay, and PR dropdown; reload config; exercise the control socket and
  `architect story <file>`; confirm terminal cwd persistence and restore.
- No behavior change is intended anywhere, so any observable difference is a
  migration defect, not an accepted trade-off.

## Risks

Ranked by likelihood times impact. Each becomes an early task so a blocker
surfaces before prep effort is sunk.

1. **`@cImport` of SDL3 headers under 0.16's Aro-based translate-c.**
   `src/c.zig` `@cImport`s `SDL3/SDL.h` and `SDL3_ttf/SDL_ttf.h` and re-exports
   224 symbols. `@cImport` still exists in 0.16, but ghostty `main`
   carries an explicit `translate_c` dependency with the note that it needs
   "fixes in Aro/translate-c itself" for the 0.16.0 release cycle. Macro and
   type translation for SDL3's headers is the most likely surprise in the whole
   migration. Verify this first, before any prep work.
2. **ghostty `main` as a dependency.** Verified only from its manifest and build
   script, not by compiling. Confirm that `zig build` resolves ghostty `main`,
   that `dep.module("ghostty-vt")` still yields the module, and that Architect's
   ghostty-vt API usage still compiles.
3. **`build.zig.zon` hash format.** All four dependency hashes must be
   regenerated with `zig fetch` under 0.16; it is unverified whether 0.16
   accepts 0.15-era hash strings at all.
4. **zig-toml `zig-0.16` API drift** against Architect's usage in `src/config.zig`
   and the persistence layer. `CLAUDE.md` records two live hazards here that any
   API change must not reintroduce: parser-owned maps must not outlive
   `result.deinit()`, and persisted map keys *and* values must both be
   duplicated.
5. **`std.Io.Writer` drift** at the 12 existing `std.Io.*` sites, including the
   `std.Io.Writer.Allocating` idiom `CLAUDE.md` documents for `toml.serialize`.

## Documentation to update

Part of the same changes as the code, per `CLAUDE.md`'s documentation-hygiene
rule.

- `CLAUDE.md` — the stack line (`Zig 0.15` to `Zig 0.16`); replace the
  "Zig 0.15 collection API differences" section with 0.16 equivalents; update
  the macOS SDK workaround repo note to match whatever the flip concludes;
  add the `io`-threading and `src/env.zig` conventions to Architecture
  Invariants. `AGENTS.md` is a symlink and needs no separate edit.
- `docs/ARCHITECTURE.md` — the new `src/env.zig`, `src/clock.zig`, and
  `src/proc.zig` shared-utility modules, and the `io` carrier data flow.
- `docs/development.md` — toolchain version and setup notes.
- `README.md` — only if it states a Zig version or prerequisites.
- `docs/perf-debugging.md` — only if the flip changes the documented
  Debug-versus-Release ghostty-vt cost characteristics.
