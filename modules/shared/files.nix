{ user, config, pkgs, homeDir, ... }:

let
  xdg_configHome = "${homeDir}/.config";
  xdg_dataHome = "${homeDir}/.local/share";
  xdg_stateHome = "${homeDir}/.local/state";
in {
  ".aider.conf.yml" = import ./config/aider.nix;
  "${xdg_configHome}/ghostty/config" = import ./config/ghostty.nix;
  "${xdg_configHome}/zellij/config.kdl" = import ./config/zellij.nix;
}
