#!/usr/bin/env bash
set -euo pipefail

echo "=== Verifying Architect Setup ==="
echo ""

echo "1. Checking Zig installation..."
if command -v zig &> /dev/null; then
    zig version
else
    echo "ERROR: zig not found. Run 'nix flake update && direnv allow' or 'nix develop'"
    exit 1
fi

echo ""
echo "2. Building project..."
zig build

echo ""
echo "3. Running tests..."
zig build test

echo ""
echo "4. Checking code formatting..."
zig fmt --check src/

echo ""
echo "=== All checks passed! ==="
