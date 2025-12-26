#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <executable> <output-dir>"
    exit 1
fi

EXECUTABLE="$1"
OUTPUT_DIR="$2"

echo "Bundling macOS application: $EXECUTABLE -> $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/lib"

cp "$EXECUTABLE" "$OUTPUT_DIR/architect"
chmod +x "$OUTPUT_DIR/architect"

seen_list=""
queue=""

enqueue() {
    local dep="$1"
    if [ -z "$dep" ]; then
        return
    fi

    if [ ! -f "$dep" ]; then
        echo "Warning: $dep not found, skipping"
        return
    fi

    if echo "$seen_list" | grep -Fxq "$dep"; then
        return
    fi

    seen_list="$seen_list
$dep"
    if [ -z "$queue" ]; then
        queue="$dep"
    else
        queue="$queue
$dep"
    fi
}

echo "Analyzing dynamic library dependencies..."
initial_deps=$(otool -L "$EXECUTABLE" | awk '/^[[:space:]]/ {print $1}' | grep '^/nix/store' || true)

if [ -z "$initial_deps" ]; then
    echo "No Nix store dependencies found"
    exit 0
fi

while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    enqueue "$dep"
done <<< "$initial_deps"

echo "Found dependencies:"
printf '  %s\n' $initial_deps

while [ -n "$queue" ]; do
    lib_path=$(printf '%s\n' "$queue" | head -n1)
    queue=$(printf '%s\n' "$queue" | tail -n +2)

    lib_name=$(basename "$lib_path")
    dest="$OUTPUT_DIR/lib/$lib_name"

    if [ ! -f "$dest" ]; then
        echo "Copying $lib_name..."
        cp "$lib_path" "$dest"
        chmod 644 "$dest"
    fi

    install_name_tool -id "@executable_path/lib/$lib_name" "$dest"

    nested_list=$(otool -L "$lib_path" | awk '/^[[:space:]]/ {print $1}' | grep '^/nix/store' || true)
    while IFS= read -r nested_dep; do
        [ -z "$nested_dep" ] && continue
        nested_name=$(basename "$nested_dep")
        install_name_tool -change "$nested_dep" "@executable_path/lib/$nested_name" "$dest"
        enqueue "$nested_dep"
    done <<< "$nested_list"
done

for original in $seen_list; do
    [ -z "$original" ] && continue
    name=$(basename "$original")
    install_name_tool -change "$original" "@executable_path/lib/$name" "$OUTPUT_DIR/architect" || true
done

echo ""
echo "Verifying final dependencies..."
if otool -L "$OUTPUT_DIR/architect" | grep -q '/nix/store'; then
    echo "Warning: Nix store references remain in architect binary"
    otool -L "$OUTPUT_DIR/architect" | grep '/nix/store'
fi

remaining=0
for file in "$OUTPUT_DIR"/lib/*.dylib; do
    if otool -L "$file" | grep -q '/nix/store'; then
        echo "Warning: Nix store references remain in $file"
        otool -L "$file" | grep '/nix/store'
        remaining=1
    fi
done

if [ $remaining -eq 0 ]; then
    echo "All bundled libraries patched to use @executable_path/lib"
fi

echo ""
echo "Bundle complete! Structure:"
find "$OUTPUT_DIR" -type f

echo ""
echo "To distribute, package the entire directory:"
echo "  cd $OUTPUT_DIR && tar -czf architect-macos.tar.gz *"
