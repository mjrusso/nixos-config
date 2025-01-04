{ user, config, pkgs, homeDir, ... }:

let
  xdg_configHome = "${homeDir}/.config";
  xdg_dataHome = "${homeDir}/.local/share";
  xdg_stateHome = "${homeDir}/.local/state";
in {

}
