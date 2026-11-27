{ user, config, pkgs, homeDir, ... }:

let
  xdg_configHome = "${homeDir}/.config";
  xdg_dataHome = "${homeDir}/.local/share";
  xdg_stateHome = "${homeDir}/.local/state";
  servePreview = pkgs.callPackage ../../packages/serve-preview {
    inherit (config.programs.servePreview) domain;
  };
in {
  ".aider.conf.yml" = import ./config/aider.nix;
  "${xdg_configHome}/ghostty/config" = import ./config/ghostty.nix;
  "${xdg_configHome}/rex/init.lua".source = pkgs.writeText "rex-init.lua" ''
    ${builtins.readFile ./config/rex/init.lua}

    do
      local serve_preview_command = ${builtins.toJSON (pkgs.lib.getExe' servePreview "serve-preview")}
      ${builtins.readFile ./config/rex/serve-preview.lua}
    end
  '';
}
