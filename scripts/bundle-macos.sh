#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
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
FONT_DEST_DIR="$SHARE_DIR/fonts"
ICON_SOURCE="assets/macos/${APP_NAME}.icns"
FONT_SOURCE_DIR="assets/fonts"

echo "Bundling macOS application: $EXECUTABLE -> $APP_DIR"

mkdir -p "$LIB_DIR" "$RESOURCES_DIR" "$FONT_DEST_DIR"

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

if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$RESOURCES_DIR/${APP_NAME}.icns"
    echo "Added app icon: $ICON_SOURCE"
else
    echo "Icon not found at $ICON_SOURCE (add an .icns file there to bundle it)"
fi

if [ -d "$FONT_SOURCE_DIR" ]; then
    echo "Bundling fonts from $FONT_SOURCE_DIR"
    if compgen -G "$FONT_SOURCE_DIR"/*.ttf > /dev/null; then
        cp "$FONT_SOURCE_DIR"/*.ttf "$FONT_DEST_DIR"/
    else
        echo "No .ttf font files found in $FONT_SOURCE_DIR; skipping font copy"
    fi
    if [ -f "$FONT_SOURCE_DIR/LICENSE" ]; then
        cp "$FONT_SOURCE_DIR/LICENSE" "$FONT_DEST_DIR"/LICENSE
    fi
else
    echo "Font source directory not found at $FONT_SOURCE_DIR"
    exit 1
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
    dest="$LIB_DIR/$lib_name"

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
    install_name_tool -change "$original" "@executable_path/lib/$name" "$MACOS_DIR/architect.bin" || true
done

echo ""
echo "Verifying final dependencies..."
if otool -L "$MACOS_DIR/architect.bin" | grep -q '/nix/store'; then
    echo "Warning: Nix store references remain in architect binary"
    otool -L "$MACOS_DIR/architect.bin" | grep '/nix/store'
fi

remaining=0
for file in "$LIB_DIR"/*.dylib; do
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
echo "  cd $OUTPUT_DIR && tar -czf architect-macos.tar.gz ${APP_NAME}.app"
