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
  depends_on xcode: :build

  def install
    system "zig", "build",
           "-Doptimize=ReleaseFast",
           "--prefix", prefix
  end

  test do
    assert_predicate bin/"architect", :exist?
  end
end
