#!/usr/bin/env python3
"""Emulate a live codex TUI session for Architect perf testing.

Streams a large styled backlog (simulating hours of agent output), then
animates a spinner. On SIGWINCH, mimics codex's resize behavior (per
openai/codex PR #18575 + captured PTY traces of codex 0.144.6): debounce,
then DEC 2026 begin, ESC[3J erase scrollback, clear screen, re-print the
last `REEMIT_LINES` transcript lines, DEC 2026 end — twice, with a lull
between the waves.

Args: [initial_lines] [reemit_lines] [mode]. Mode "active" (default) keeps a
status line ticking through the lull and between resizes; "idle" stays
silent like a codex waiting for input.
"""
import signal
import sys
import time

INITIAL_LINES = int(sys.argv[1]) if len(sys.argv) > 1 else 30000
REEMIT_LINES = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
IDLE = len(sys.argv) > 3 and sys.argv[3] == "idle"

resize_pending = False


def on_winch(_sig, _frame):
    global resize_pending
    resize_pending = True


signal.signal(signal.SIGWINCH, on_winch)

out = sys.stdout


def styled_line(i):
    return (
        f"\x1b[38;5;{(i * 7) % 230 + 1}m•\x1b[0m \x1b[1mstep {i}\x1b[0m "
        f"\x1b[36mrunning tool\x1b[0m with output \x1b[33mwarning\x1b[0m lorem ipsum "
        f"dolor sit amet consectetur \x1b[32m+{i % 97}\x1b[0m \x1b[31m-{i % 13}\x1b[0m "
        f"adipiscing elit sed do eiusmod tempor incididunt ut labore\r\n"
    )


def emit_block(n, start=0):
    buf = []
    for i in range(start, start + n):
        buf.append(styled_line(i))
        if len(buf) >= 200:
            out.write("".join(buf))
            out.flush()
            buf.clear()
    out.write("".join(buf))
    out.flush()


emit_block(INITIAL_LINES)

i = INITIAL_LINES
spin = "|/-\\"
k = 0
while True:
    time.sleep(0.1)
    if resize_pending:
        resize_pending = False
        time.sleep(0.15)
        # Live codex re-emits its reflowed tail twice per resize (initial
        # rebuild + final source-backed rebuild, openai/codex PR #18575),
        # paced through its streaming path: two waves with a lull between.
        for wave in range(2):
            out.write("\x1b[?2026h\x1b[3J\x1b[1;1H\x1b[J")
            chunk = 50
            emitted = 0
            while emitted < REEMIT_LINES:
                n = min(chunk, REEMIT_LINES - emitted)
                emit_block(n, start=max(0, i - REEMIT_LINES) + emitted)
                emitted += n
                time.sleep(0.06)
            out.write("\x1b[?2026l")
            out.flush()
            if wave == 0:
                if IDLE:
                    time.sleep(1.5)
                else:
                    for tick in range(15):
                        out.write(f"\r\x1b[K\x1b[36m{spin[tick % 4]}\x1b[0m reflowing...")
                        out.flush()
                        time.sleep(0.1)
    elif not IDLE:
        k += 1
        out.write(f"\r\x1b[K\x1b[36m{spin[k % 4]}\x1b[0m working... \x1b[2m({k}s)\x1b[0m")
        out.flush()
