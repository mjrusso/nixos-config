{ pkgs }:

with pkgs;
let shared-packages = import ../shared/packages.nix { inherit pkgs; }; in
shared-packages ++ [
  openssh
  home-manager
  gnumake
  cmake
  direnv
  tree
  inotify-tools
  sqlite
]
