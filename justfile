default:
    @just --list

build:
    zig build

test:
    zig build test

lint:
    zig fmt --check src/

ci: build test lint
