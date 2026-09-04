{ pkgs }:

let
  sharedPackages = import ../shared/packages.nix { inherit pkgs; };
in
sharedPackages
++ [
  pkgs.ncurses
  pkgs.ghostty.terminfo
]
