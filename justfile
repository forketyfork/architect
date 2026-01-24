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
    #!/usr/bin/env bash
    set -euo pipefail

    sh_files=()
    while IFS= read -r -d '' file; do
        sh_files+=("$file")
    done < <(find scripts -type f -name '*.sh' -print0)
    if [ -f scripts/verify-setup.sh ]; then
        sh_files+=("scripts/verify-setup.sh")
    fi
    if [ ${#sh_files[@]} -ne 0 ]; then
        shellcheck "${sh_files[@]}"
    fi

    py_files=()
    while IFS= read -r -d '' file; do
        py_files+=("$file")
    done < <(find scripts -type f -name '*.py' -print0)
    if [ ${#py_files[@]} -ne 0 ]; then
        ruff check "${py_files[@]}"
    fi

    zig fmt --check src/

    zig build lint

ci: build test lint
