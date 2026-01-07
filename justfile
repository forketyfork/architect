default:
    @just --list

setup:
    #!/usr/bin/env bash
    # Pre-fetch ghostty tarball into the Zig cache (no checkout needed)
    url=$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("build.zig.zon").read_text()
m = re.search(r'\.url\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "", end="")
PY
)
    if [ -z "$url" ]; then
        echo "ghostty URL not found in build.zig.zon" >&2
        exit 1
    fi
    zig fetch --global-cache-dir .zig-cache "$url"

build:
    zig build

test:
    zig build test

run:
    zig build run

run-release:
    zig build run -Doptimize=ReleaseFast

lint:
    zig fmt --check src/

ci: build test lint
