# Performance Debugging

Techniques for investigating Architect rendering/terminal performance, distilled
from the grid/full toggle lag investigation (July 2026, follow-up to issue #299).

## Measuring CPU and wakeups

Use `scripts/perf/cpu_probe.sh <pid> [seconds]` on macOS to sample a live
Architect process. The script uses macOS `top -stats idlew` to report average
CPU percentage and idle wakeups per second, then compares each thread's
cumulative CPU time from `ps -M` before and after the sampling window. It
defaults to a 30-second window; pass the same duration for before/after
comparisons. The probe is macOS-only because both `top -stats idlew` and
`ps -M` are macOS options.

The notification and control socket listeners block in `poll(2)` on their
listening socket plus a `WakePipe` self-pipe, so their former 10 ms accept-loop
polling does not contribute steady-state wakeups. Shutdown sets each stop flag
and signals its pipe before joining the listener thread.

Use a `-Doptimize=ReleaseFast` build for performance measurements. For the
repeatable six-session setup, follow the isolated-instance procedure below,
run the probe in Grid and Full view, and probe the daily instance. The metrics
overlay also reports loop iterations, presented frames, deferred output
renders, skipped epoch bumps, and full/partial cache refresh rates; the latter
counters distinguish full-texture redraws from row-level partial refreshes.

## Dirty tracking

The renderer owns ghostty-vt dirty-bit consumption after refreshing a session's
persistent render-target texture. It takes the full path for a new or recreated
texture; terminal- or screen-wide dirty flags; a dirty page; viewport, layout,
hovered-link, color, or dead-state changes in the cache `ContentKey`; cache
composition/render-mode changes; and baked wave overlays. A normal scrollback
scroll also takes the full path because its viewport pin changes the key.

When the key differs only in cursor position and there are no wide/page dirty
bits, the renderer clears and redraws just dirty row strips plus the previous
and current cursor rows. Each strip is cleared to the session background before
the row is rasterized, so overwriting wide CJK or emoji glyphs cannot leave
pixels behind. Rows near full-cell glyphs or box-drawing characters always take
the full path because `renderClusterFill` overdraws by `pad_px` and procedural
box drawing can also extend past its cell rectangle. Full refreshes clear
terminal, screen, page, and row dirty bits; partial refreshes clear only row
dirty bits and leave wider dirty sources for a future full refresh.

`ghostty marks only the printed row dirty for an in-place rewrite and the page
for a scroll` in `src/render/renderer.zig` is the upgrade canary for this
contract. Ghostty also marks the row a cursor moved *off* dirty in
`Screen.cursorChangePin`; that expected false positive is safe because the
partial path redraws both cursor rows. The canary uses a no-scrollback terminal
for its scroll assertion so it exercises the in-place page-dirty path; regular
scrollback scrolling is guarded by the viewport key instead.

### Energy baseline (2026-09-02)

The six isolated result rows below are ReleaseFast builds, each measured by the
maintainer on macOS with an isolated instance, six
`scripts/perf/fake_codex.py 3000 1000` sessions rewriting a spinner row at
10 Hz, no user input during a 60 s probe, and a 1400x900 window. Full view
costs more main-thread CPU than Grid in the baseline even though only one
session is visible, because every spinner tick re-rasterizes the whole
138x46-cell texture. The
daily-instance row was probed on 2026-09-02 against the Homebrew build
(v0.68.2) during active use, 1h10m after launch; the main thread had already
accumulated 30m28s of CPU time, about 43% of one core averaged over its
uptime. Idle wakeups swing widely with activity: two 30-60 s probes minutes
apart read 38/s and 194/s.

| main commit | scenario | avg CPU% | idle wakeups/s | main thread CPU per 60 s |
| --- | --- | --- | --- | --- |
| e21ffb1 (Task 1 only) | Grid | 22.2 | 116 | +13.45 s |
| e21ffb1 (Task 1 only) | Full, 138x46 cells | 24.6 | 92 | +18.00 s |
| 5f2b806 (Tasks 2-3: wake pipes) | Grid | 22.8 | 0.1 | +13.52 s |
| 6b91e05 (Task 4: frame scheduling) | Grid | 14.4 | 0.0 | +8.30 s (54 cache re-renders/s, every tick drawn) |
| 7def241 (Tasks 5-6 + #389, #392) | Grid | 10.9 | 0.3 | +5.39 s (67 partial cache refreshes/s) |
| 7def241 (Tasks 5-6 + #389, #392) | Full, 138x46 cells | 3.9 | 0.0 | +1.77 s (11 partial cache refreshes/s) |
| Homebrew v0.68.2 (before this work) | daily instance, active use, 7 sessions | 14.5-15.4 | 38-194 | +4.85 s over a 30 s probe; other threads <= +0.18 s |

Wakeups vanished with Tasks 2-3 while CPU was unchanged because the CPU was
all rendering; Task 4 halved presents; the row-level refresh made Full view
six times cheaper than the baseline because one spinner row is redrawn instead
of 138x46 cells; the remaining Grid cost is dominated by compositing seven
textures plus per-tile overlays at up to 30 presents/s.

### Measurement pitfalls

- A probe with near-zero CPU and zero `rendering to cache` debug lines means
  the window was fully covered, because macOS occlusion suppresses rendering.
  Always count those lines alongside a probe and keep the window visible.
- Under change-driven scheduling, any `wantsFrame` that stays true pins the
  loop at the display refresh rate (120 Hz on the maintainer's display). A
  sudden 2-3x CPU jump after user interaction is almost always that class of
  bug; the three found today were fixed in #392, #393, and #395. Hide
  transitions arm guards too, so `markDrawn()` belongs at the top of `render`
  before any visibility early return. The metrics overlay's `Present/s` line is
  the quickest tell since #392.
- `sample <pid>` shows wall time: `nextDrawable`/semaphore frames are blocked
  time, not CPU. Look at SDL command-queue, `SDL_FindInHashTable`, line/rect
  drawing, and glyph leaves for real CPU.

## Reproducing without manual UI interaction

- Run an isolated instance with a **short** fake `HOME` (e.g. `/tmp/arch-ph`):
  the control unix-socket path must stay under the 104-char `sockaddr_un` limit
  or the control thread dies silently. Create `$HOME/.config/architect` and
  seed `persistence.toml` with a realistic `[window]` size so the render target
  matches production usage. This isolates config, persistence, logs, and the
  control socket from the daily instance.
- Spawn sessions programmatically through the control socket at
  `$HOME/Library/Caches/Architect/runtime/architect_control_<pid>.sock`: send
  one JSON line `{"cwd": "...", "command": "...", "display_name": "..."}`.
  The command is typed into the new session's shell, so an inline
  `HOME=/Users/<real-user> codex ...` prefix restores the real home for child
  tools while the app itself stays isolated.
- `scripts/perf/fake_codex.py` emulates a live codex TUI cell: it streams a
  large styled backlog, animates a spinner, and on SIGWINCH mimics codex's
  resize behavior (debounce, DEC 2026 begin, `ESC[3J`, re-print the last N
  transcript lines, DEC 2026 end).
- For deterministic view toggles, temporarily add an env-gated auto-toggle to
  the main loop in `runtime.zig` (set `.Expanding`, or call
  `grid_nav.startCollapseToGrid`). Grid→Full is Cmd+Return; Full→Grid is the
  escape-hold path (`RequestCollapseFocused`).

## Codex resize behavior (measured on codex-cli 0.144.6)

On **any** PTY resize (rows-only included) codex debounces, then emits
`ESC[?2026h`, `ESC[3J` (erases the entire scrollback!), clears the screen, and
re-prints the tail of its transcript wrapped in synchronized-output pairs.
The tail length is capped by `[tui.terminal_resize_reflow].max_rows`
(openai/codex PR #18575); Architect's `TERM=xterm-ghostty` maps to the default
fallback cap of 1000 rows.

**Live vs. resumed sessions differ drastically in pacing.** A freshly resumed
session (`codex resume`) flushes the whole ~200 KB re-emit in under 100 ms. A
long-running **live** session re-emits its reflowed tail **twice** per resize
(the initial rebuild plus a "final source-backed rebuild" — see PR #18575),
paced through codex's streaming path: 80–250 KB trickling in over **3–5
seconds** in two waves separated by a ~1.5 s lull. Ground-truth measurement
(instrumented ReleaseFast build, real 6-cell session, July 2026): Architect's
frames stayed at 3–20 ms and VT resizes at 0–1 ms throughout — the
seconds-long "scrolling text" after a grid/full toggle is entirely
producer-side codex pacing, not Architect's consumption. Resumed-session
probes therefore *cannot* reproduce the toggle lag; only live sessions with
real transcript history can. Architect renders that repaint live, the way
Ghostty does: whatever the app draws is what appears on screen, and the
picture converges once the app finishes redrawing.

## Chatty small-write producers (JVM/JLine TUIs)

JLine-based TUIs (e.g. Junie CLI) repaint the full screen every frame inside
a DEC-2026 window (`ESC[?2026h … ESC[?2026l`) as ~150 small (~190-byte)
`write()` syscalls, up to ~19fps. Before the dedicated PTY reader thread
(2026-08), the frame-paced drain stopped at the first EWOULDBLOCK, so drain
boundaries landed mid-window ~97% of the time: the renderer's sync hold
suppressed nearly every repaint (2–9 effective fps), the kernel PTY buffer
backed up, and the producer's writes blocked 250–800 ms per frame — the
user-visible ~1s/keypress lag. Diagnostics that pinned it: the producer's
own write-latency telemetry (`[tui-perf] write p95` in `~/.junie/logs`), a
PTY harness capturing chunk sizes and 2026 markers per read, and per-read
DRAIN/SYNC-HOLD debug logging in an isolated instance. The key control was
that with the window occluded (rendering suppressed), the old drain kept up
and writes took 2 ms — proof the drain was render-paced, not slow. Producers
that write whole frames in one syscall (codex, claude) never exhibited this.

## Measured costs (ghostty-vt 1.3.1, Apple Silicon)

| Operation | Debug | ReleaseSafe/ReleaseFast |
| --- | --- | --- |
| Feed 180 KB codex resize re-emit | 7–12 s | ~1 ms |
| `Terminal.resize` (cols change, 10 MB styled scrollback) | 1.4–2.4 s | 3–5 ms |
| `Terminal.resize` (rows-only change) | ~0 ms | ~0 ms |

The Debug numbers are dominated by ghostty's `slow_runtime_safety` page
integrity verification (enabled only for Debug optimize mode, see ghostty's
`src/build/Config.zig`). Never draw performance conclusions from a plain
Debug build; benchmark VT behavior with `-Doptimize=ReleaseFast`.

## SDL/Metal pipeline pitfalls

- Destroying an `SDL_Texture` that was queued for rendering in the current
  frame forces SDL's Metal backend to flush the command queue
  (`SDL_DestroyTextureInternal` → `METAL_RunCommandQueue` →
  `METAL_ActivateRenderCommandEncoder` → `CAMetalLayer nextDrawable`), and
  `nextDrawable` can block for up to ~1 s when the drawable pool is exhausted.
  Never create-render-destroy a texture per frame; cache static textures
  (see `src/ui/components/glyph_badge.zig`).
- Scrollable text previews must not materialize one SDL texture per logical
  line. Cache the wrapped byte ranges needed for scroll metrics, but keep
  textures only for the visible viewport plus a small overscan window (see
  `src/ui/components/selection_agent_overlay.zig`).
- **Occluded windows stop getting drawables.** When the window is fully
  covered (another window on top, Space switch), macOS stops compositing it
  and `nextDrawable` blocks for its full ~1 s timeout on every render attempt,
  freezing the main thread — input handling and PTY draining included. This
  presented as sporadic ~1.1–1.2 s single-frame stalls that survived every
  content-side fix; the `SDL_WINDOW_OCCLUDED` window flag at stall time was
  the discriminating evidence. The frame loop now skips rendering while the
  flag is set (`shouldRenderFrame` in `app/runtime.zig`) and repaints on the
  `SDL_EVENT_WINDOW_EXPOSED` event.
- `sample <pid> <secs> -file out.txt` attributes these waits precisely; look
  for `nextDrawable` under the component that happens to flush first.
- A deterministic way to test occlusion behavior: launch a second isolated
  Architect instance with the identical `[window]` rect so it exactly covers
  the first.

## Reading the evidence

- Structured app logs (`~/Library/Logs/Architect/architect.log`) record
  grid/full transitions (`event=view_enter_full` etc.) and, at debug level,
  `rendering to cache: session=N` lines — enough to correlate user-visible
  stalls with render churn, but only with second granularity.
- With `[logging].min_level = "debug"`, each VT resize logs
  `session N: terminal resized, AxB -> CxD` (scope `layout`), which pins the
  exact moment a SIGWINCH went out and the cell counts on either side of it.
- For millisecond attribution, add temporary timing around
  `applyTerminalResize`, `processOutput`, and the render pass, and print
  per-frame lines to stderr.
