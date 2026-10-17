{
  lib,
  pkgs,
  userInfo,
  ...
}:
let
  guestAgent = pkgs.writeScriptBin "voom-guest-services" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../../packages/voom-macos-guest/agent.py
  );
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

  # macOS creates the first-boot account outside nix-darwin's managed users.
  system.activationScripts.postActivation.text = ''
    /usr/bin/dscl . -create ${lib.escapeShellArg "/Users/${userInfo.user}"} UserShell /run/current-system/sw/bin/fish
  '';

  environment.etc."voom/guest-services.json".text = builtins.toJSON {
    schemaVersion = 1;
    capabilities = {
      controlShare = true;
      guestPortReport = true;
      guestShareMount = true;
      nixosSwitch = false;
    };
  };
  launchd.daemons.voom-guest-services.serviceConfig = {
    Label = "org.voom.guest-services";
    ProgramArguments = [ "${guestAgent}/bin/voom-guest-services" ];
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 5;
    StandardOutPath = "/var/log/voom-guest-services.log";
    StandardErrorPath = "/var/log/voom-guest-services.log";
  };

  power.sleep.computer = "never";
}
