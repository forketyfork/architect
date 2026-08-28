#!/usr/bin/env bash
# Provision Architect in AIR Cloud without Nix, apt, sudo, or root access.
# Zig supplies the C compiler used for the two SDL builds; all other tools are
# portable user-space archives. SDL 3.4.10 is parsed from the project's overlay
# so this remains aligned with the normal development environment.
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
  local url="$1" dest="$2"
  if [ ! -s "$dest" ]; then
    log "downloading $(basename "$dest")"
    curl --fail --location --retry 3 --silent --show-error -o "$dest" "$url"
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
if [ ! -x "$zig_dir/zig" ]; then
  rm -rf "$zig_dir.tmp"
  mkdir "$zig_dir.tmp"
  extract_tar "$zig_archive" "$zig_dir.tmp"
  mv "$zig_dir.tmp/zig-x86_64-linux-$zig_version" "$zig_dir"
  rmdir "$zig_dir.tmp"
fi
ln -sfn "$zig_dir/zig" "$bin_dir/zig"
export PATH="$bin_dir:$PATH"
if [ ! -x "$bin_dir/zig-ar" ]; then
  printf '#!/usr/bin/env bash\nexec "%s" ar "$@"\n' "$zig_dir/zig" > "$bin_dir/zig-ar"
  printf '#!/usr/bin/env bash\nexec "%s" ranlib "$@"\n' "$zig_dir/zig" > "$bin_dir/zig-ranlib"
  chmod +x "$bin_dir/zig-ar" "$bin_dir/zig-ranlib"
fi

cmake_version=3.31.8
cmake_archive="$src_dir/cmake-$cmake_version-linux-x86_64.tar.gz"
download "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-linux-x86_64.tar.gz" "$cmake_archive"
cmake_dir="$prefix/cmake-$cmake_version"
if [ ! -x "$cmake_dir/bin/cmake" ]; then
  extract_tar "$cmake_archive" "$prefix"
  mv "$prefix/cmake-$cmake_version-linux-x86_64" "$cmake_dir"
fi
export PATH="$cmake_dir/bin:$PATH"

ninja_version=1.12.1
ninja_archive="$src_dir/ninja-linux.zip"
download "https://github.com/ninja-build/ninja/releases/download/v$ninja_version/ninja-linux.zip" "$ninja_archive"
if [ ! -x "$bin_dir/ninja" ]; then
  python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract("ninja",sys.argv[2])' "$ninja_archive" "$bin_dir"
  chmod +x "$bin_dir/ninja"
fi

download_archive_bin() {
  local name="$1" archive="$2" url="$3"; local target="$bin_dir/$name"
  if [ ! -x "$target" ]; then
    download "$url" "$src_dir/$archive"
    mkdir -p "$src_dir/$name"; extract_tar "$src_dir/$archive" "$src_dir/$name"
    cp "$src_dir/$name"/*/"$name" "$target" 2>/dev/null || cp "$src_dir/$name/$name" "$target"
    chmod +x "$target"
  fi
}
download_archive_bin just just-1.40.0.tar.gz "https://github.com/casey/just/releases/download/1.40.0/just-1.40.0-x86_64-unknown-linux-musl.tar.gz"
download_archive_bin shellcheck shellcheck-0.10.0.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz"
download_archive_bin ruff ruff-0.12.10.tar.gz "https://github.com/astral-sh/ruff/releases/download/0.12.10/ruff-x86_64-unknown-linux-gnu.tar.gz"

sdl_version="$(sed -n 's/.*version = "\([0-9][0-9.]*\)".*/\1/p' "$project_dir/overlays/sdl3-3-4-10.nix" | head -1)"
[ -n "$sdl_version" ] || sdl_version=3.4.10
build_sdl() {
  local name="$1" url="$2" source="$src_dir/$1" build="$src_dir/$1-build"
  shift 2
  if [ ! -f "$sdl_prefix/.${name}.installed" ]; then
    local build_started="$(seconds_now)"
    download "$url" "$src_dir/$name.tar.gz"
    rm -rf "$source" "$build" "$source.tmp"; mkdir -p "$source.tmp" "$build"
    extract_tar "$src_dir/$name.tar.gz" "$source.tmp"
    mkdir "$source"; cp -a "$source.tmp"/*/. "$source"/
    if [ "$name" = SDL_ttf ]; then
      ( cd "$source/external" && ./download.sh )
    fi
    local cmake_prefix_args=()
    if [ "$name" = SDL_ttf ]; then
      cmake_prefix_args=(-DCMAKE_PREFIX_PATH="$sdl_prefix")
    fi
    ( cd "$build"; CC="$zig_dir/zig cc" CXX="$zig_dir/zig c++" cmake -G Ninja "$source" -DCMAKE_AR="$bin_dir/zig-ar" -DCMAKE_RANLIB="$bin_dir/zig-ranlib" "${cmake_prefix_args[@]}" "$@"; cmake --build .; cmake --install . )
    touch "$sdl_prefix/.${name}.installed"
    log "$name build and install completed in $(( $(seconds_now) - build_started ))s"
  fi
}
build_sdl SDL "https://github.com/libsdl-org/SDL/archive/refs/tags/release-$sdl_version.tar.gz" \
  -DCMAKE_INSTALL_PREFIX="$sdl_prefix" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
  -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_ALSA=OFF -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF \
  -DSDL_JACK=OFF -DSDL_SNDIO=OFF -DSDL_KMSDRM=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF \
  -DSDL_VULKAN=OFF -DSDL_CAMERA=OFF -DSDL_HIDAPI=OFF -DSDL_VIDEO_DRIVER_DUMMY=ON \
  -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_INSTALL=ON
build_sdl SDL_ttf "https://github.com/libsdl-org/SDL_ttf/archive/refs/tags/release-3.2.2.tar.gz" \
  -DCMAKE_INSTALL_PREFIX="$sdl_prefix" -DSDLTTF_VENDORED=ON -DSDLTTF_SAMPLES=OFF -DSDLTTF_TESTS=OFF

export SDL3_INCLUDE_PATH="$sdl_prefix/include"
export SDL3_TTF_INCLUDE_PATH="$sdl_prefix/include"
# Zig 0.15's HTTP client cannot reliably use AIR Cloud's injected proxy, while
# direct HTTPS works. Clear it after all curl/git provisioning has finished.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
sed -i '/^# Architect AIR Cloud toolchain$/,/^unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy$/d' "$profile"
profile_line='# Architect AIR Cloud toolchain\nexport PATH="$HOME/.local/bin:$HOME/.local/cmake-3.31.8/bin:$PATH"\nexport SDL3_INCLUDE_PATH="$HOME/.local/sdl3-prefix/include"\nexport SDL3_TTF_INCLUDE_PATH="$HOME/.local/sdl3-prefix/include"\ncase ":${LD_LIBRARY_PATH:-}:" in *":$HOME/.local/sdl3-prefix/lib:"*) ;; *) export LD_LIBRARY_PATH="$HOME/.local/sdl3-prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac\nunset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy'
printf '%b\n' "$profile_line" >> "$profile"
case ":${LD_LIBRARY_PATH:-}:" in *":$sdl_prefix/lib:"*) ;; *) export LD_LIBRARY_PATH="$sdl_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac

log "ready: zig $(zig version), cmake $(cmake --version | head -1)"
