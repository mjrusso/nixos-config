{ config, osConfig, pkgs, ... }:

let user = "mjrusso"; in

{
  imports = [
    ../../modules/linux/home-manager.nix
    ../../modules/shared
  ];

  # Setup user, packages, programs
  nix = {
    package = pkgs.nixVersions.git;
    settings.trusted-users = [ "@admin" "${user}" ];
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  programs.home-manager.enable = true;
  programs.fish.enable = true;
}
