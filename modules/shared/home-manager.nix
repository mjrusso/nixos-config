{ config, osConfig, pkgs, lib, userInfo, ... }:

let
  commonArgs = {
    inherit config osConfig pkgs lib;
    name = userInfo.name;
    user = userInfo.user;
    email = userInfo.email;
  };
in {
  direnv = import ./config/direnv.nix commonArgs;
  fish = import ./config/fish.nix commonArgs;
  gh = import ./config/gh.nix commonArgs;
  git = import ./config/git.nix commonArgs;
  npm = import ./config/npm.nix commonArgs;
  zoxide = import ./config/zoxide.nix commonArgs;
  tmux = import ./config/tmux.nix commonArgs;
}
