#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <executable> <output-dir>"
    exit 1
fi

EXECUTABLE="$1"
OUTPUT_DIR="$2"

echo "Bundling macOS application: $EXECUTABLE -> $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/lib"

cp "$EXECUTABLE" "$OUTPUT_DIR/architect"
chmod +x "$OUTPUT_DIR/architect"

echo "Analyzing dynamic library dependencies..."
DYLIBS=$(otool -L "$EXECUTABLE" | grep -E '^\s+/nix/store' | awk '{print $1}' || true)

if [ -z "$DYLIBS" ]; then
    echo "No Nix store dependencies found"
    exit 0
fi

echo "Found dependencies:"
echo "$DYLIBS"

for dylib in $DYLIBS; do
    if [ ! -f "$dylib" ]; then
        echo "Warning: $dylib not found, skipping"
        continue
    fi

    dylib_name=$(basename "$dylib")
    echo "Copying $dylib_name..."
    cp "$dylib" "$OUTPUT_DIR/lib/"
    chmod 644 "$OUTPUT_DIR/lib/$dylib_name"

    echo "Fixing install name for $dylib_name in executable..."
    install_name_tool -change "$dylib" "@executable_path/lib/$dylib_name" "$OUTPUT_DIR/architect"

    nested_dylibs=$(otool -L "$dylib" | grep -E '^\s+/nix/store' | awk '{print $1}' || true)
    for nested_dylib in $nested_dylibs; do
        if [ ! -f "$nested_dylib" ]; then
            continue
        fi

        nested_name=$(basename "$nested_dylib")
        if [ ! -f "$OUTPUT_DIR/lib/$nested_name" ]; then
            echo "Copying nested dependency $nested_name..."
            cp "$nested_dylib" "$OUTPUT_DIR/lib/"
            chmod 644 "$OUTPUT_DIR/lib/$nested_name"
        fi

        echo "Fixing install name for $nested_name in $dylib_name..."
        install_name_tool -change "$nested_dylib" "@executable_path/lib/$nested_name" "$OUTPUT_DIR/lib/$dylib_name"
    done
done

echo ""
echo "Verifying final dependencies..."
otool -L "$OUTPUT_DIR/architect"

echo ""
echo "Bundle complete! Structure:"
find "$OUTPUT_DIR" -type f

echo ""
echo "To distribute, package the entire directory:"
echo "  cd $OUTPUT_DIR && tar -czf architect-macos.tar.gz *"
