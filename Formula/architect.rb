class Architect < Formula
  desc "Terminal window manager with AI-powered workspace orchestration"
  homepage "https://github.com/forketyfork/architect"
  url "https://github.com/forketyfork/architect/archive/refs/tags/v0.38.0.tar.gz"
  sha256 "9103708a381f47169cd350279e0478543299cb705f8e1eb4ea6a04314a3b53bc"
  license "MIT"

  depends_on "pkg-config" => :build
  depends_on "zig" => :build
  depends_on xcode: :build
  depends_on "sdl3"
  depends_on "sdl3_ttf"

  def install
    system "zig", "build",
           "-Doptimize=ReleaseFast"

    app_name = "Architect"
    app_path = prefix/"#{app_name}.app"
    contents = app_path/"Contents"
    macos = contents/"MacOS"
    resources = contents/"Resources"
    share = contents/"share/architect"

    macos.mkpath
    resources.mkpath

    (contents/"Info.plist").write <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>#{app_name}</string>
          <key>CFBundleDisplayName</key>
          <string>#{app_name}</string>
          <key>CFBundleIdentifier</key>
          <string>com.forketyfork.architect</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleExecutable</key>
          <string>architect</string>
          <key>CFBundleIconFile</key>
          <string>#{app_name}</string>
          <key>CFBundleVersion</key>
          <string>#{version}</string>
          <key>CFBundleShortVersionString</key>
          <string>#{version}</string>
        </dict>
      </plist>
    EOS

    (macos/"architect").write <<~EOS
      #!/bin/bash
      SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
      exec "$SCRIPT_DIR/architect.bin" "$@"
    EOS

    chmod 0755, macos/"architect"

    (macos/"architect.bin").write (buildpath/"zig-out/bin/architect").read
    chmod 0755, macos/"architect.bin"

    resources.install "assets/macos/#{app_name}.icns"
  end

  def caveats
    <<~EOS
      Architect.app has been installed to:
        #{prefix}/Architect.app

      To add it to your Applications folder (for Spotlight/Launchpad access):
        cp -r #{prefix}/Architect.app /Applications/

      Launch with:
        open -a Architect
    EOS
  end

  test do
    assert_path_exists prefix/"Architect.app/Contents/MacOS/architect"
  end
end
