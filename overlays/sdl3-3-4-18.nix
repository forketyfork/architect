final: prev: {
  sdl3 = prev.sdl3.overrideAttrs (old: rec {
    version = "3.4.18";

    src = prev.fetchFromGitHub {
      owner = "libsdl-org";
      repo = "SDL";
      rev = "release-${version}";
      hash = "sha256-3dP4FJ5OvZI6UPykJpE3hTH6kdW+Nn7gUSf3yiPCobo=";
    };

    # Drop nixpkgs' Linux-only zenity substitutions that no longer match SDL 3.4.x.
    # Keep the test timeout bump to avoid slow CTest hangs.
    postPatch = ''
      substituteInPlace test/CMakeLists.txt \
        --replace-fail 'set(noninteractive_timeout 10)' 'set(noninteractive_timeout 30)'
    '';

    buildInputs =
      old.buildInputs
      ++ prev.lib.optionals prev.stdenv.isLinux [
        prev.xorg.libXtst
      ];
  });
}
