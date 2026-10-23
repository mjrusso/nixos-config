{
  config,
  lib,
  pkgs,
  userInfo,
  hostInfo,
  ...
}:
let
  cfg = config.services.voomBackup;
  user = userInfo.user;
  home = config.users.users.${user}.home;
  hostBackup = config.services.restic.backups.${hostInfo.nixosHostname} or null;
  resticCommand = "restic-${hostInfo.nixosHostname}";
in
{
  options.services.voomBackup = {
    enable = lib.mkEnableOption "daily file backups of running Linux Voom guests";
    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.ssh/id_ed25519_voom_read";
      description = "SSH private key without a passphrase. Its public key must match userInfo.voomReadKey.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hostBackup != null && hostBackup.createWrapper && hostBackup.user == user;
        message = ''services.voomBackup requires services.restic.backups.${hostInfo.nixosHostname} with createWrapper = true and user = "${user}".'';
      }
      {
        assertion = (userInfo.voomReadKey or "") != "";
        message = "Set userInfo.voomReadKey and rebuild the Linux guests before enabling Voom backups.";
      }
    ];

    systemd.services.voom-backup = {
      description = "Back up running Voom guests into the restic repository";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        # The staging dataset disables snapshots; see disk-config.nix.
        CacheDirectory = "voom-staging";
      };
      path = [
        pkgs.voom
        pkgs.jq
        pkgs.rsync
        pkgs.openssh
      ]
      ++ builtins.filter (p: (p.name or "") == resticCommand) config.environment.systemPackages;
      script = ''
        # Voom uses HOME for state and XDG_RUNTIME_DIR for running-guest pidfiles.
        export HOME=${lib.escapeShellArg home}
        export XDG_RUNTIME_DIR="/run/user/$UID"
        export VOOM_BACKUP_USER=${lib.escapeShellArg user}
        export VOOM_BACKUP_IDENTITY=${lib.escapeShellArg cfg.identityFile}
        export VOOM_BACKUP_RESTIC=${lib.escapeShellArg resticCommand}
        exec ${pkgs.bash}/bin/bash ${../../scripts/voom-backup-linux}
      '';
    };

    systemd.timers.voom-backup = {
      description = "Daily Voom guest backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
