{ userInfo, ... }:
{
  # bake-macos installs Nix with nixbld GID 350. The shared
  # system.stateVersion = 4 defaults to 30000, causing activation to fail.
  ids.gids.nixbld = 350;
  environment.etc."mjr-vm-guest".text = "1\n";
  security.sudo.extraConfig = ''
    ${userInfo.user} ALL=(ALL) NOPASSWD: ALL
  '';
  power.sleep.computer = "never";
}
