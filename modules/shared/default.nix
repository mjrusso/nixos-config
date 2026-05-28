{ config, osConfig, pkgs, emacs-flake, voom, ... }:

{

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowBroken = true;
      allowInsecure = false;
      allowUnsupportedSystem = true;
    };

    overlays =
      [
        (final: prev: {
          my-emacs-with-packages = emacs-flake.packages.${prev.stdenv.hostPlatform.system}.default;
          voom = voom.packages.${prev.stdenv.hostPlatform.system}.default;
        })
      ] ++
      # Apply each overlay found in the /overlays directory
      (let path = ../../overlays; in with builtins;
       map (n: import (path + ("/" + n)))
           (filter (n: match ".*\\.nix" n != null ||
                       pathExists (path + ("/" + n + "/default.nix")))
                   (attrNames (readDir path))));
  };
}
