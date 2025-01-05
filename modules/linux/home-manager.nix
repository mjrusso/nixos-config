{ config, osConfig, pkgs, lib, home-manager, ... }:

let
  user = "mjrusso";
  homeDir = "/home/${user}.linux";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };
in {
  home = {
    username = user;
    homeDirectory = homeDir;
    enableNixpkgsReleaseCheck = false;
    packages = pkgs.callPackage ./packages.nix { };
    sessionPath = [ "$HOME/.local/bin" ];
    sessionVariables = {
      EDITOR = "ec";
      TERMINFO_DIRS = "$HOME/.nix-profile/share/terminfo";
    };
    file = lib.mkMerge [ sharedFiles additionalFiles ];
    stateVersion = "23.11";
  };

  news.display = "silent";

  fonts.fontconfig.enable = true;

  programs = { } // import ../shared/home-manager.nix {
    inherit config osConfig pkgs lib;
  };
}
