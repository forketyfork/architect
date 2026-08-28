#!/usr/bin/env bash
# Provision Architect in AIR Cloud without Nix, apt, sudo, or root access.
# Zig supplies the C compiler used for the two SDL builds; all other tools are
# portable user-space archives. SDL 3.4.10 is parsed from the project's overlay
# so this remains aligned with the normal development environment.
#
# This provisions disposable, non-production CI sandboxes rather than release
# artifacts. Downloads use pinned HTTPS release URLs but intentionally do not
# carry SHA256 values: maintaining checksums for every platform archive and the
# mutable third-party submodules fetched by SDL_ttf's upstream download script
# would add substantial churn. Do not reuse this bootstrap for a release build.
set -euo pipefail

log() { printf '[air-startup] %s\n' "$*"; }
die() { printf '[air-startup] ERROR: %s\n' "$*" >&2; exit 1; }
seconds_now() { date +%s; }

project_dir="${FLEET_WORKSPACE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
home_dir="${HOME:?HOME is required}"
prefix="$home_dir/.local"
bin_dir="$prefix/bin"
src_dir="$prefix/src"
sdl_prefix="$prefix/sdl3-prefix"
profile="$home_dir/.profile"
mkdir -p "$bin_dir" "$src_dir" "$sdl_prefix"

download() {
  local url="$1" dest="$2" temp="$2.tmp"
  if [ ! -s "$dest" ]; then
    log "downloading $(basename "$dest")"
    rm -f "$temp"
    curl --fail --location --retry 3 --silent --show-error -o "$temp" "$url"
    mv "$temp" "$dest"
  fi
}
extract_tar() {
  # Python's stdlib supports .xz even when the minimal image has no xz binary.
  python3 -c 'import sys,tarfile; tarfile.open(sys.argv[1], "r:*").extractall(sys.argv[2], filter="data")' "$1" "$2"
}

zig_version="$(sed -n 's/.*minimum_zig_version = "\([0-9][0-9.]*\)".*/\1/p' "$project_dir/build.zig.zon")"
[ -n "$zig_version" ] || die "could not read minimum_zig_version"
zig_archive="$src_dir/zig-x86_64-linux-$zig_version.tar.xz"
zig_download_started="$(seconds_now)"
download "https://ziglang.org/download/$zig_version/zig-x86_64-linux-$zig_version.tar.xz" "$zig_archive"
log "Zig download completed in $(( $(seconds_now) - zig_download_started ))s"
zig_dir="$prefix/zig-$zig_version"
if [ ! -x "$zig_dir/zig" ] || [ "$("$zig_dir/zig" version 2>/dev/null || true)" != "$zig_version" ]; then
  rm -rf "$zig_dir" "$zig_dir.tmp"
  mkdir "$zig_dir.tmp"
  extract_tar "$zig_archive" "$zig_dir.tmp"
  mv "$zig_dir.tmp/zig-x86_64-linux-$zig_version" "$zig_dir"
  rmdir "$zig_dir.tmp"
fi
ln -sfn "$zig_dir/zig" "$bin_dir/zig"
export PATH="$bin_dir:$PATH"
printf '#!/usr/bin/env bash\nexec "%s" ar "$@"\n' "$zig_dir/zig" > "$bin_dir/zig-ar"
printf '#!/usr/bin/env bash\nexec "%s" ranlib "$@"\n' "$zig_dir/zig" > "$bin_dir/zig-ranlib"
chmod +x "$bin_dir/zig-ar" "$bin_dir/zig-ranlib"

cmake_version=3.31.8
cmake_archive="$src_dir/cmake-$cmake_version-linux-x86_64.tar.gz"
download "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-linux-x86_64.tar.gz" "$cmake_archive"
cmake_dir="$prefix/cmake-$cmake_version"
if [ ! -x "$cmake_dir/bin/cmake" ] || [ "$("$cmake_dir/bin/cmake" --version 2>/dev/null | sed -n '1s/^cmake version //p')" != "$cmake_version" ]; then
  rm -rf "$cmake_dir"
  extract_tar "$cmake_archive" "$prefix"
  mv "$prefix/cmake-$cmake_version-linux-x86_64" "$cmake_dir"
fi
export PATH="$cmake_dir/bin:$PATH"

ninja_version=1.12.1
ninja_archive="$src_dir/ninja-$ninja_version-linux.zip"
download "https://github.com/ninja-build/ninja/releases/download/v$ninja_version/ninja-linux.zip" "$ninja_archive"
if [ ! -x "$bin_dir/ninja" ] || [ "$("$bin_dir/ninja" --version 2>/dev/null || true)" != "$ninja_version" ]; then
  python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract("ninja",sys.argv[2])' "$ninja_archive" "$bin_dir"
  chmod +x "$bin_dir/ninja"
fi

download_archive_bin() {
  local name="$1" archive="$2" url="$3"; local target="$bin_dir/$name"
  local expected_version="$4"
  if ! tool_version_matches "$name" "$target" "$expected_version"; then
    download "$url" "$src_dir/$archive"
    mkdir -p "$src_dir/$name"; extract_tar "$src_dir/$archive" "$src_dir/$name"
    cp "$src_dir/$name"/*/"$name" "$target" 2>/dev/null || cp "$src_dir/$name/$name" "$target"
    chmod +x "$target"
  fi
}
tool_version_matches() {
  local name="$1" target="$2" expected_version="$3" actual_version
  [ -x "$target" ] || return 1
  case "$name" in
    just|ruff) actual_version="$("$target" --version 2>/dev/null | awk '{print $2}')" ;;
    shellcheck) actual_version="$("$target" --version 2>/dev/null | sed -n 's/^version: //p')" ;;
    *) die "no version check defined for $name" ;;
  esac
  [ "$actual_version" = "$expected_version" ]
}
download_archive_bin just just-1.40.0.tar.gz "https://github.com/casey/just/releases/download/1.40.0/just-1.40.0-x86_64-unknown-linux-musl.tar.gz" 1.40.0
download_archive_bin shellcheck shellcheck-0.10.0.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz" 0.10.0
download_archive_bin ruff ruff-0.12.10.tar.gz "https://github.com/astral-sh/ruff/releases/download/0.12.10/ruff-x86_64-unknown-linux-gnu.tar.gz" 0.12.10

sdl_version="$(sed -n 's/.*version = "\([0-9][0-9.]*\)".*/\1/p' "$project_dir/overlays/sdl3-3-4-10.nix" | head -1)"
[ -n "$sdl_version" ] || die "could not read SDL3 version from overlay"
sdl_ttf_version=3.2.2
build_sdl() {
  local name="$1" version="$2" url="$3" source="$src_dir/$1" build="$src_dir/$1-build"
  local marker="$sdl_prefix/.${name}.installed"
  local archive="$src_dir/$name-$version.tar.gz"
  local build_started
  shift 3
  if [ "$(cat "$marker" 2>/dev/null || true)" != "$version" ]; then
    build_started="$(seconds_now)"
    download "$url" "$archive"
    rm -rf "$source" "$build" "$source.tmp"; mkdir -p "$source.tmp" "$build"
    extract_tar "$archive" "$source.tmp"
    mkdir "$source"; cp -a "$source.tmp"/*/. "$source"/
    if [ "$name" = SDL_ttf ]; then
      ( cd "$source/external" && ./download.sh )
    fi
    local cmake_prefix_args=()
    if [ "$name" = SDL_ttf ]; then
      cmake_prefix_args=(-DCMAKE_PREFIX_PATH="$sdl_prefix")
    fi
    ( cd "$build"; CC="$zig_dir/zig cc" CXX="$zig_dir/zig c++" cmake -G Ninja "$source" -DCMAKE_AR="$bin_dir/zig-ar" -DCMAKE_RANLIB="$bin_dir/zig-ranlib" "${cmake_prefix_args[@]}" "$@"; cmake --build .; cmake --install . )
    printf '%s\n' "$version" > "$marker"
    log "$name build and install completed in $(( $(seconds_now) - build_started ))s"
  fi
}
build_sdl SDL "$sdl_version" "https://github.com/libsdl-org/SDL/archive/refs/tags/release-$sdl_version.tar.gz" \
  -DCMAKE_INSTALL_PREFIX="$sdl_prefix" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
  -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_ALSA=OFF -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF \
  -DSDL_JACK=OFF -DSDL_SNDIO=OFF -DSDL_KMSDRM=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF \
  -DSDL_VULKAN=OFF -DSDL_CAMERA=OFF -DSDL_HIDAPI=OFF -DSDL_VIDEO_DRIVER_DUMMY=ON \
  -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_INSTALL=ON
build_sdl SDL_ttf "$sdl_ttf_version" "https://github.com/libsdl-org/SDL_ttf/archive/refs/tags/release-$sdl_ttf_version.tar.gz" \
  -DCMAKE_INSTALL_PREFIX="$sdl_prefix" -DSDLTTF_VENDORED=ON -DSDLTTF_SAMPLES=OFF -DSDLTTF_TESTS=OFF

export SDL3_INCLUDE_PATH="$sdl_prefix/include"
export SDL3_TTF_INCLUDE_PATH="$sdl_prefix/include"
# Zig 0.15's HTTP client cannot reliably use AIR Cloud's injected proxy, while
# direct HTTPS works. Clear it after all curl/git provisioning has finished.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
touch "$profile"
sed -i '/^# >>> Architect AIR Cloud toolchain >>>$/,/^# <<< Architect AIR Cloud toolchain <<</d' "$profile"
# shellcheck disable=SC2016 # This is deliberately expanded when the profile is sourced.
profile_line='# >>> Architect AIR Cloud toolchain >>>\nexport PATH="$HOME/.local/bin:$HOME/.local/cmake-3.31.8/bin:$PATH"\nexport SDL3_INCLUDE_PATH="$HOME/.local/sdl3-prefix/include"\nexport SDL3_TTF_INCLUDE_PATH="$HOME/.local/sdl3-prefix/include"\ncase ":${LD_LIBRARY_PATH:-}:" in *":$HOME/.local/sdl3-prefix/lib:"*) ;; *) export LD_LIBRARY_PATH="$HOME/.local/sdl3-prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac\nunset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy\n# <<< Architect AIR Cloud toolchain <<<'
printf '%b\n' "$profile_line" >> "$profile"
case ":${LD_LIBRARY_PATH:-}:" in *":$sdl_prefix/lib:"*) ;; *) export LD_LIBRARY_PATH="$sdl_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac

log "ready: zig $(zig version), cmake $(cmake --version | head -1)"
