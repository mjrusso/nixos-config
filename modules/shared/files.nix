{ user, config, pkgs, ... }:

let
  xdg_configHome = "${config.users.users.${user}.home}/.config";
  xdg_dataHome = "${config.users.users.${user}.home}/.local/share";
  xdg_stateHome = "${config.users.users.${user}.home}/.local/state";
in {

  ".aider.conf.yml" = import ./config/aider.nix;

  "${xdg_configHome}/ghostty/config" = import ./config/ghostty.nix;

  "${xdg_configHome}/zellij/config.kdl" = import ./config/zellij.nix;

}
