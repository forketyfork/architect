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
    sha256 "122022d77cfd6d901de978a2667797a18d82f7ce2fd6c40d4028d6db603499dc9679"
  end

  def install
    ENV["ZIG_GLOBAL_CACHE_DIR"] = buildpath/"zig-cache"

    resource("ghostty").stage do |r|
      system "zig", "fetch",
             "--global-cache-dir", ENV["ZIG_GLOBAL_CACHE_DIR"],
             r.cached_download
    end

    system "zig", "build",
           "-Doptimize=ReleaseFast",
           "--prefix", prefix

    bin.install "zig-out/bin/architect"
    (share/"architect/fonts").install Dir["zig-out/share/architect/fonts/*"]
  end

  test do
    assert_predicate bin/"architect", :exist?
  end
end
