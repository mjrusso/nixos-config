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

  services = {
    hypridle = lib.mkIf osConfig.services.localDesktop.enable {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || ${lib.getExe config.programs.hyprlock.package}";
          before_sleep_cmd = "loginctl lock-session";
        };
        listener = [
          {
            timeout = 600;
            on-timeout = "loginctl lock-session";
          }
        ];
      };
    };
    udiskie.enable = true;

    dunst = {
      enable = true;
      package = pkgs.dunst;
      settings = {
        global = {
          monitor = 0;
          follow = "mouse";
          border = 0;
          height = 400;
          width = 320;
          offset = "33x65";
          indicate_hidden = "yes";
          shrink = "no";
          separator_height = 0;
          padding = 32;
          horizontal_padding = 32;
          frame_width = 0;
          sort = "no";
          idle_threshold = 120;
          font = "Noto Sans";
          line_height = 4;
          markup = "full";
          format = "<b>%s</b>\n%b";
          alignment = "left";
          transparency = 10;
          show_age_threshold = 60;
          word_wrap = "yes";
          ignore_newline = "no";
          stack_duplicates = false;
          hide_duplicate_count = "yes";
          show_indicators = "no";
          icon_position = "left";
          icon_theme = "Adwaita-dark";
          sticky_history = "yes";
          history_length = 20;
          history = "ctrl+grave";
          browser = "google-chrome-stable";
          always_run_script = true;
          title = "Dunst";
          class = "Dunst";
          max_icon_size = 64;
        };
      };
    };
  };

  programs = shared-programs // {
    hyprlock = lib.mkIf osConfig.services.localDesktop.enable {
      enable = true;
      settings = {
        background = [ { color = "rgb(1a1a1a)"; } ];
        input-field = [
          {
            monitor = "";
            size = "300, 50";
            position = "0, -80";
          }
        ];
      };
    };
  };
}
