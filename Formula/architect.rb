class Architect < Formula
  desc "Terminal window manager with AI-powered workspace orchestration"
  homepage "https://github.com/forketyfork/architect"
  url "https://github.com/forketyfork/architect/archive/refs/tags/v0.11.0.tar.gz"
  sha256 "559ef8d4a7b9107279eb4e741ca8bdd951c17d37c2180211e5dbc7a5dd19b0ca"
  license "MIT"

  depends_on "pkg-config" => :build
  depends_on "zig" => :build
  depends_on "sdl3"
  depends_on "sdl3_ttf"

  resource "ghostty" do
    url "https://github.com/ghostty-org/ghostty/archive/f705b9f46a4083d8053cfa254898c164af46ff34.tar.gz"
    sha256 "a3588866217e11940a89a4e383955aa97b0dc9ebfd3a8b2fb92107e3fbf69276"
  end

  def install
    ENV["ZIG_GLOBAL_CACHE_DIR"] = buildpath/"zig-cache"

    system "zig", "fetch",
           "--global-cache-dir", ENV["ZIG_GLOBAL_CACHE_DIR"],
           resource("ghostty").cached_download

    system "zig", "build",
           "-Doptimize=ReleaseFast",
           "--prefix", prefix
  end

  test do
    assert_predicate bin/"architect", :exist?
  end
end
