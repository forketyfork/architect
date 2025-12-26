{
  description = "Architect development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-24_05.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-24_05, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
        legacy = import nixpkgs-24_05 {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
        sdl2 = legacy.SDL2;
        sdl2_ttf = legacy.SDL2_ttf;
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            just
            zig.packages.${system}."0.15.2"
            pkg-config
          ];

          buildInputs =
            [
              sdl2.dev
              sdl2_ttf
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.gawk
              pkgs.gnused
            ];

          shellHook = ''
            export PKG_CONFIG_PATH="${sdl2}/lib/pkgconfig:${sdl2_ttf}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export SDL2_INCLUDE_PATH="${sdl2.dev}/include"
            export SDL2_TTF_INCLUDE_PATH="${sdl2_ttf}/include"
            echo "Architect development environment"
            echo "Available commands: just --list"
          ''
          + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # On macOS, we unset the macOS SDK env vars that Nix sets up because
            # we rely on a system installation.
            unset SDKROOT
            unset DEVELOPER_DIR

            # We need to remove "xcrun" from the PATH. It is injected by
            # some dependency but we need to rely on system Xcode tools
            export PATH=$(echo "$PATH" | ${pkgs.gawk}/bin/awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | ${pkgs.gnused}/bin/sed 's/:$//')
          '');
        };
      }
    );
}
