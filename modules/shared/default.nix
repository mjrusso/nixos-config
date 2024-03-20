{ config, osConfig, pkgs, emacs-overlay, ... }:

{

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowBroken = true;
      allowInsecure = false;
      allowUnsupportedSystem = true;
    };

    overlays =
      [(import emacs-overlay)] ++
      # Apply each overlay found in the /overlays directory
      (let path = ../../overlays; in with builtins;
       map (n: import (path + ("/" + n)))
           (filter (n: match ".*\\.nix" n != null ||
                       pathExists (path + ("/" + n + "/default.nix")))
                   (attrNames (readDir path))));
  };
}
