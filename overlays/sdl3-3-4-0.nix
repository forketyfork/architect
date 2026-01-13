final: prev: {
  sdl3 = prev.sdl3.overrideAttrs (old: rec {
    version = "3.4.0";

    src = prev.fetchFromGitHub {
      owner = "libsdl-org";
      repo = "SDL";
      rev = "release-${version}";
      hash = "sha256-/A1y/NaZVebzI58F4TlwtDwuzlcA33Y1YuZqd5lz/Sk=";
    };
  });
}
