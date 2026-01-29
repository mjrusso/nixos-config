{ config, osConfig, pkgs, lib, ... }:

let
  user = "mjrusso";
  homeDir = "/home/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };
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
    };
    file = lib.mkMerge [ sharedFiles additionalFiles ];
    stateVersion = "24.11";
  };

  news.display = "silent";

  programs = { } // import ../shared/home-manager.nix {
    inherit config osConfig pkgs lib;
  };
}
