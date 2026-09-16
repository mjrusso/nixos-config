{ pkgs }:

with pkgs;
let shared-packages = import ../shared/packages.nix {
  inherit pkgs;
  llmAgentPolicy = {
    useVoomEgress = true;
    claudeArguments = [ "--dangerously-skip-permissions" ];
    codexArguments = [ "--yolo" ];
  };
}; in
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
