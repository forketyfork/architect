default:
    @just --list

setup:
    #!/usr/bin/env bash
    if [ ! -d "ghostty" ]; then
        echo "Cloning ghostty-org/ghostty..."
        git clone https://github.com/ghostty-org/ghostty.git ghostty
    else
        echo "ghostty directory already exists"
    fi

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
