default:
    @just --list

setup:
    #!/usr/bin/env bash
    # Pre-fetch ghostty tarball into the Zig cache (no checkout needed)
    url=$(sed -n 's/.*\.url *= *"\(.*\)".*/\1/p' build.zig.zon | head -1)
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
