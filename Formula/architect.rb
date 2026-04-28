class Architect < Formula
  desc "Terminal window manager with AI-powered workspace orchestration"
  homepage "https://github.com/forketyfork/architect"
  url "https://github.com/forketyfork/architect/archive/refs/tags/v0.61.0.tar.gz"
  sha256 "2ba9a100c7b284e6d2d357c206d8a2c1ec3e26a5994af73c873926bdf784ca6f"
  license "MIT"

  depends_on "pkg-config" => :build
  depends_on "zig@0.15" => :build
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
          <key>NSHighResolutionCapable</key>
          <true/>
          <key>NSAppleEventsUsageDescription</key>
          <string>A program running in Architect would like to use AppleScript.</string>
          <key>NSCameraUsageDescription</key>
          <string>A program running in Architect would like to use the camera.</string>
          <key>NSMicrophoneUsageDescription</key>
          <string>A program running in Architect would like to use your microphone.</string>
          <key>NSContactsUsageDescription</key>
          <string>A program running in Architect would like to access your Contacts.</string>
          <key>NSCalendarsUsageDescription</key>
          <string>A program running in Architect would like to access your Calendar.</string>
          <key>NSLocationUsageDescription</key>
          <string>A program running in Architect would like to access your location.</string>
          <key>NSPhotoLibraryUsageDescription</key>
          <string>A program running in Architect would like to access your Photo Library.</string>
        </dict>
      </plist>
    EOS

    macos.install buildpath/"zig-out/bin/architect"
    macos.install buildpath/"zig-out/bin/architect-mcp"
    bin.install_symlink macos/"architect-mcp" => "architect-mcp"

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

      MCP helper command:
        architect-mcp

      MCP helper app-bundle path:
        #{prefix}/Architect.app/Contents/MacOS/architect-mcp
    EOS
  end

  test do
    assert_path_exists prefix/"Architect.app/Contents/MacOS/architect"
    assert_path_exists prefix/"Architect.app/Contents/MacOS/architect-mcp"
    assert_path_exists bin/"architect-mcp"
  end
end
