{ config, osConfig, pkgs, lib, ... }:

let
  commonArgs = {
    inherit config osConfig pkgs lib;
    name = "Michael Russo";
    user = "mjrusso";
    email = "mjr@mjrusso.com";
  };
in {
  direnv = import ./config/direnv.nix commonArgs;
  fish = import ./config/fish.nix  commonArgs;
  git = import ./config/git.nix  commonArgs;
  zoxide = import ./config/zoxide.nix commonArgs;
}
