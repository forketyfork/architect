#!/bin/sh

# Work around Zig 0.15.2 failing to link against the macOS 26.4 SDK family,
# whose top-level libSystem.tbd no longer advertises arm64-macos.
# Upstream tracker: https://codeberg.org/ziglang/zig/issues/31756
#
# Remove this once Architect no longer uses Zig 0.15.2, or once Zig's Darwin
# SDK discovery/linker handles the arm64e-only stub layout correctly.

legacy_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
default_stub="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib/libSystem.tbd"

if [ ! -d "$legacy_sdk" ] || [ ! -f "$default_stub" ]; then
    return 0
fi

if sed -n '1,5p' "$default_stub" | grep -q 'arm64-macos'; then
    return 0
fi

project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
workaround_root="$project_root/.tmp/macos-sdk-workaround"
bin_dir="$workaround_root/bin"
developer_dir="$workaround_root/developer"
sdk_link="$developer_dir/SDKs/MacOSX.sdk"

mkdir -p "$bin_dir" "$developer_dir/SDKs"
ln -sfn "$legacy_sdk" "$sdk_link"

xcrun_wrapper="$bin_dir/xcrun"
cat > "$xcrun_wrapper" <<EOF
#!/bin/sh

if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ] && [ "\$#" -eq 3 ]; then
    printf '%s\n' '$legacy_sdk'
    exit 0
fi

exec env DEVELOPER_DIR= /usr/bin/xcrun "\$@"
EOF
chmod +x "$xcrun_wrapper"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) export PATH="$bin_dir:$PATH" ;;
esac

export DEVELOPER_DIR="$developer_dir"

echo "Applied Zig 0.15.2 macOS SDK workaround using $legacy_sdk"
