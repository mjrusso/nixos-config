{ pkgs, systemType }:

with pkgs;
let
  shared-packages = import ../shared/packages.nix {
    inherit pkgs;
    llmAgentPolicy = {
      claudeArguments = lib.optional (systemType == "vm") "--dangerously-skip-permissions";
      codexArguments = lib.optional (systemType == "vm") "--yolo";
    };
  };
in
shared-packages
++ lib.optionals (systemType != "vm") [
  lima
  colima
  docker
  docker-compose
  kitty
  voom
]
