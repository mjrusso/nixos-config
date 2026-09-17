{ config, osConfig, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  homeDir = "/home/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };
  sharedPrograms = import ../shared/home-manager.nix {
    inherit config osConfig pkgs lib userInfo;
  };
  voomEgressRun = pkgs.callPackage ../../packages/voom-egress-run.nix { };
  mkVoomEgressWrapper = pkgs.callPackage ../../packages/mk-voom-egress-wrapper.nix {
    inherit voomEgressRun;
  };
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
    gh.package = mkVoomEgressWrapper {
      package = pkgs.gh;
      program = "gh";
    };
    git.package = mkVoomEgressWrapper {
      package = pkgs.git;
      program = "git";
    };
  };
}
