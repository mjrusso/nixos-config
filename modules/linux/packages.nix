{ pkgs }:

with pkgs;
let shared-packages = import ../shared/packages.nix { inherit pkgs; }; in
shared-packages ++ [
  ncurses
  ghostty

  # Virtualization
  krunvm # Create microVMs from OCI images: https://github.com/containers/krunvm
  buildah # OCI image build tool: https://github.com/containers/buildah
]
