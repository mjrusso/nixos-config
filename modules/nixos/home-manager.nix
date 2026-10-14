{
  config,
  osConfig,
  pkgs,
  lib,
  userInfo,
  ...
}:

let
  user = userInfo.user;
  shared-programs = import ../shared/home-manager.nix {
    inherit
      config
      osConfig
      pkgs
      lib
      userInfo
      ;
  };
  homeDir = "/home/${user}";
  shared-files = import ../shared/files.nix {
    inherit
      user
      config
      pkgs
      homeDir
      ;
  };

in
{
  home = {
    enableNixpkgsReleaseCheck = false;
    username = "${user}";
    homeDirectory = "/home/${user}";
    packages = pkgs.callPackage ./packages.nix { };
    sessionPath = [
      "$HOME/.local/bin"
    ];
    sessionVariables = {
      PATH = "$PATH:$HOME/.npm/bin";
      EDITOR = "ec";
      TERMINFO_DIRS = lib.concatStringsSep ":" [
        "$HOME/.nix-profile/share/terminfo"
        "/etc/profiles/per-user/${user}/share/terminfo"
        "/run/current-system/sw/share/terminfo"
      ];
    };
    file = shared-files;
    stateVersion = "21.05";
  };

  gtk = {
    enable = true;
    iconTheme = {
      name = "Adwaita-dark";
      package = pkgs.adwaita-icon-theme;
    };
    theme = {
      name = "Adwaita-dark";
      package = pkgs.adwaita-icon-theme;
    };
    gtk4.theme = config.gtk.theme;
  };

  services.udiskie.enable = true;

  programs = shared-programs;
}
