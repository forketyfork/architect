{
  description = "Architect development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            just
            zig.packages.${system}."0.15.2"
            SDL2
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.gawk
            pkgs.gnused
          ];

          shellHook = ''
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
