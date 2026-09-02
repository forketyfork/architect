#!/usr/bin/env bash
# macOS-only: top -stats idlew and ps -M use macOS-specific options.
# Samples CPU% and idle wakeups/s of one process with `top`, and reports how much
# CPU time (system + user) each thread accumulated over the window (via `ps -M`).
# Usage: scripts/perf/cpu_probe.sh <pid> [seconds]   (default 30 s)
set -euo pipefail

pid="${1:?usage: cpu_probe.sh <pid> [seconds]}"
seconds="${2:-30}"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "pid $pid is not running" >&2
    exit 1
fi

# One line per thread: "<main|thread> <cpu seconds>". `ps -M` prints STIME and
# UTIME as mm:ss.cc columns; only the first (main) thread row carries COMMAND,
# so a last field that is not a time marks the main thread.
thread_cpu_seconds() {
    ps -M -p "$1" | awk '
        NR == 1 { next }
        {
            total = 0; times = 0; label = "thread"
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+:[0-9]+\.[0-9]+$/) {
                    split($i, part, /[:.]/)
                    total += part[1] * 60 + part[2] + part[3] / 100
                    times++
                }
            }
            if ($NF !~ /^[0-9]+:[0-9]+\.[0-9]+$/) label = "main"
            if (times == 2) printf "%s %.2f\n", label, total
        }'
}

before="$(thread_cpu_seconds "$pid")"

# The first top sample reports averages since process start; skip it.
samples=$((seconds + 1))
top -l "$samples" -s 1 -pid "$pid" -stats pid,cpu,idlew \
    | awk -v pid="$pid" '
        $1 == pid { n++; if (n > 1) { cpu += $2; idlew_last = $3; if (n == 2) idlew_first = $3 } }
        END {
            if (n < 2) { print "no samples captured"; exit 1 }
            printf "samples: %d\n", n - 1
            printf "avg cpu%%: %.2f\n", cpu / (n - 1)
            printf "idle wakeups/s: %.1f\n", (idlew_last - idlew_first) / (n - 1)
        }'

after="$(thread_cpu_seconds "$pid")"

# Rows pair up by position; if the thread count changed during the window the
# tail of the list is misaligned, but the main thread (first row) stays valid.
echo "per-thread cpu seconds (system+user) before -> after (delta):"
paste <(echo "$before") <(echo "$after") | awk '{ printf "  %-6s %9.2f -> %9.2f  (+%.2f)\n", $1, $2, $4, $4 - $2 }'
