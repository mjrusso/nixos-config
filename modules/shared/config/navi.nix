{ config, ... }:

{
  enable = true;

  # home-manager turns this on by default. It binds Ctrl-G in fish.
  enableFishIntegration = false;

  # The cheat files come from a separate, private configuration.
  settings.cheats.paths = [ "${config.xdg.dataHome}/navi/cheats" ];
}
