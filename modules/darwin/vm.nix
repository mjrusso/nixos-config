{
  lib,
  pkgs,
  userInfo,
  ...
}:
let
  source = userInfo.voomReadKeySource or "";
  from = lib.optionalString (source != "") '',from="${source}"'';
in
{
  # bake-macos installs Nix with nixbld GID 350. The shared
  # system.stateVersion = 4 defaults to 30000, causing activation to fail.
  ids.gids.nixbld = 350;
  environment.etc."mjr-vm-guest".text = "1\n";
  security.sudo.extraConfig = ''
    ${userInfo.user} ALL=(ALL) NOPASSWD: ALL
  '';
  environment.systemPackages = [ pkgs.ghostty-bin.terminfo ];
  users.users.${userInfo.user}.openssh.authorizedKeys.keys =
    lib.optional ((userInfo.voomReadKey or "") != "")
      ''restrict,command="sudo --preserve-env=SSH_ORIGINAL_COMMAND ${pkgs.rrsync}/bin/rrsync -ro /Users"${from} ${userInfo.voomReadKey}'';

  # MacOS creates the first-boot account outside nix-darwin's managed users.
  system.activationScripts.postActivation.text = ''
    /usr/bin/dscl . -create ${lib.escapeShellArg "/Users/${userInfo.user}"} UserShell /run/current-system/sw/bin/fish
  '';

  power.sleep.computer = "never";
}
