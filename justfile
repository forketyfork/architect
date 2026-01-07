default:
    @just --list

setup:
    #!/usr/bin/env bash
    # Pre-fetch ghostty tarball into the Zig cache (no checkout needed)
    zig fetch --global-cache-dir .zig-cache https://github.com/ghostty-org/ghostty/archive/f705b9f46a4083d8053cfa254898c164af46ff34.tar.gz

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
