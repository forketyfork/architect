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

lint:
    zig fmt --check src/

ci: build test lint
