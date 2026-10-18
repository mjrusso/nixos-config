{ pkgs, systemType }:

with pkgs;
let shared-packages = import ../shared/packages.nix { inherit pkgs; }; in
shared-packages ++ lib.optionals (systemType != "vm") [
  lima
  colima
  docker
  docker-compose
  kitty
  voom
]
