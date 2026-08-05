#!/usr/bin/env bash
# Zig only collects tests from files it actually analyzes, so a file with tests
# that nothing references is compiled but never run — silently. src/main.zig
# keeps an explicit registry (`test { _ = @import(...); }`) for that reason;
# this check fails when a file declaring tests is missing from it.
set -euo pipefail

cd "$(dirname "$0")/.."

registry=src/main.zig
# Files covered by the separate mcp test binary (see build.zig).
mcp_roots=("src/mcp/main.zig" "src/app/control.zig")

missing=()
while IFS= read -r file; do
    rel=${file#src/}

    [ "$file" = "$registry" ] && continue
    skip=false
    for root in "${mcp_roots[@]}"; do
        [ "$file" = "$root" ] && skip=true
    done
    $skip && continue

    if ! grep -qF "@import(\"$rel\")" "$registry"; then
        missing+=("$file")
    fi
done < <(grep -rl '^test ' src --include='*.zig' | sort)

if [ ${#missing[@]} -ne 0 ]; then
    echo "error: these files declare tests but are not registered in $registry," >&2
    echo "so their tests never run. Add '_ = @import(\"<path>\");' to its test block:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "test registry: all $(grep -rl '^test ' src --include='*.zig' | wc -l | tr -d ' ') files with tests are reachable"
