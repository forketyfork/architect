#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <executable> <output-dir>"
    exit 1
fi

EXECUTABLE="$1"
OUTPUT_DIR="$2"
APP_NAME="Architect"
APP_DIR="$OUTPUT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LIB_DIR="$MACOS_DIR/lib"
SHARE_DIR="$CONTENTS_DIR/share/architect"
ICON_SOURCE="assets/macos/${APP_NAME}.icns"

echo "Bundling macOS application: $EXECUTABLE -> $APP_DIR"

mkdir -p "$LIB_DIR" "$RESOURCES_DIR" "$SHARE_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.forketyfork.architect</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>architect</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
  </dict>
</plist>
EOF

if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$RESOURCES_DIR/${APP_NAME}.icns"
    echo "Added app icon: $ICON_SOURCE"
else
    echo "Icon not found at $ICON_SOURCE (add an .icns file there to bundle it)"
fi

# Keep the real binary as architect.bin and provide a wrapper that sets env vars
cp "$EXECUTABLE" "$MACOS_DIR/architect.bin"
chmod +x "$MACOS_DIR/architect.bin"

cat > "$MACOS_DIR/architect" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
export DYLD_FALLBACK_LIBRARY_PATH="${SCRIPT_DIR}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-/lib:/usr/lib}"
exec "${SCRIPT_DIR}/architect.bin" "$@"
EOS
chmod +x "$MACOS_DIR/architect"

seen_list=""
queue=""

enqueue() {
    local dep="$1"
    if [[ -z "$dep" ]]; then
        return
    fi

    if [[ ! -f "$dep" ]]; then
        echo "Warning: $dep not found, skipping"
        return
    fi

    if printf '%s\n' "$seen_list" | grep -Fxq "$dep"; then
        return
    fi

    seen_list="$seen_list
$dep"
    if [[ -z "$queue" ]]; then
        queue="$dep"
    else
        queue="$queue
$dep"
    fi
}

echo "Analyzing dynamic library dependencies..."
initial_deps=$(otool -L "$EXECUTABLE" | awk '/^[[:space:]]/ {print $1}' | grep '^/nix/store' || true)

if [[ -z "$initial_deps" ]]; then
    echo "No Nix store dependencies found"
    exit 0
fi

while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    enqueue "$dep"
done <<< "$initial_deps"

echo "Found dependencies:"
while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    printf '  %s\n' "$dep"
done <<< "$initial_deps"

while [[ -n "$queue" ]]; do
    if [[ "$queue" == *$'\n'* ]]; then
        lib_path="${queue%%$'\n'*}"
        queue="${queue#*$'\n'}"
    else
        lib_path="$queue"
        queue=""
    fi

    lib_name=$(basename "$lib_path")
    dest="$LIB_DIR/$lib_name"

    if [[ ! -f "$dest" ]]; then
        echo "Copying $lib_name..."
        cp "$lib_path" "$dest"
        chmod 644 "$dest"
    fi

    install_name_tool -id "@executable_path/lib/$lib_name" "$dest"

    nested_list=$(otool -L "$lib_path" | awk '/^[[:space:]]/ {print $1}' | grep '^/nix/store' || true)
    while IFS= read -r nested_dep; do
        [[ -z "$nested_dep" ]] && continue
        nested_name=$(basename "$nested_dep")
        install_name_tool -change "$nested_dep" "@executable_path/lib/$nested_name" "$dest"
        enqueue "$nested_dep"
    done <<< "$nested_list"
done

while IFS= read -r original; do
    [[ -z "$original" ]] && continue
    name=$(basename "$original")
    install_name_tool -change "$original" "@executable_path/lib/$name" "$MACOS_DIR/architect.bin" || true
done <<< "$seen_list"

echo ""
echo "Verifying final dependencies..."
if otool -L "$MACOS_DIR/architect.bin" | grep -q '/nix/store'; then
    echo "Warning: Nix store references remain in architect binary"
    otool -L "$MACOS_DIR/architect.bin" | grep '/nix/store'
fi

remaining=0
shopt -s nullglob
for file in "$LIB_DIR"/*.dylib; do
    if otool -L "$file" | grep -q '/nix/store'; then
        echo "Warning: Nix store references remain in $file"
        otool -L "$file" | grep '/nix/store'
        remaining=1
    fi
done
shopt -u nullglob

if [[ $remaining -eq 0 ]]; then
    echo "All bundled libraries patched to use @executable_path/lib"
fi

echo ""
echo "Bundle complete! Structure:"
find "$OUTPUT_DIR" -type f

echo ""
echo "To distribute, package the entire directory:"
echo "  cd $OUTPUT_DIR && tar -czf architect-macos.tar.gz ${APP_NAME}.app"
