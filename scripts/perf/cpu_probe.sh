#!/usr/bin/env bash
# macOS-only: top -stats idlew and ps -M use macOS-specific options.
# Samples CPU% and idle wakeups/s of one process with `top`, and reports how much
# CPU time each thread accumulated over the window (via `ps -M`).
# Usage: scripts/perf/cpu_probe.sh <pid> [seconds]   (default 30 s)
set -euo pipefail

pid="${1:?usage: cpu_probe.sh <pid> [seconds]}"
seconds="${2:-30}"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "pid $pid is not running" >&2
    exit 1
fi

before="$(ps -M -p "$pid" | tail -n +2 | awk '{print $NF}')"

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

after="$(ps -M -p "$pid" | tail -n +2 | awk '{print $NF}')"

echo "per-thread cpu time (mm:ss.ms) before -> after:"
paste <(echo "$before") <(echo "$after") | awk '{ printf "  %s -> %s\n", $1, $2 }'
