{ config, osConfig, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  homeDir = "/home/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };
  sharedPrograms = import ../shared/home-manager.nix {
    inherit config osConfig pkgs lib userInfo;
  };
  voomEgressFunction = command: ''
    if test "$VOOM_EGRESS_ACTIVE" != 1; and test -r /run/voom/egress.json
        voom-egress-run -- (command -s ${command}) $argv
    else
        command ${command} $argv
    end
  '';
in {
  home = {
    username = user;
    homeDirectory = homeDir;
    enableNixpkgsReleaseCheck = false;
    packages = pkgs.callPackage ./packages.nix { };
    sessionPath = [
      "$HOME/.local/bin"
    ];
    sessionVariables = {
      PATH = "$PATH:$HOME/.npm/bin";
      EDITOR = "ec";
    };
    file = lib.mkMerge [ sharedFiles additionalFiles ];
    stateVersion = "24.11";
  };

  news.display = "silent";

  programs = lib.recursiveUpdate sharedPrograms {
    fish.functions = {
      gh = voomEgressFunction "gh";
      git = voomEgressFunction "git";
    };
  };
}
