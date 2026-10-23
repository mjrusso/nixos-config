{
  config,
  lib,
  pkgs,
  userInfo,
  systemType,
  ...
}:
let
  cfg = config.services.voomBackup;
  home = config.users.users.${userInfo.user}.home;
  repositoryEnvironment = ''
    export RESTIC_REPOSITORY=${lib.escapeShellArg cfg.repository}
    export RESTIC_PASSWORD_FILE=${lib.escapeShellArg cfg.passwordFile}
  '';
  backup = pkgs.writeShellApplication {
    name = "voom-backup";
    runtimeInputs = [
      pkgs.voom
      pkgs.jq
      pkgs.rsync
      pkgs.openssh
      pkgs.restic
      pkgs.coreutils
    ];
    text =
      repositoryEnvironment
      + ''
        export VOOM_BACKUP_VOLUME=${lib.escapeShellArg cfg.volume}
        export VOOM_BACKUP_STAGE=${lib.escapeShellArg cfg.stagingDirectory}
        export VOOM_BACKUP_IDENTITY=${lib.escapeShellArg cfg.identityFile}
      ''
      + lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ../../scripts/voom-backup-macos);
  };
  restic = pkgs.writeShellScriptBin "restic-voom" (
    repositoryEnvironment
    + ''
      exec ${pkgs.restic}/bin/restic "$@"
    ''
  );
in
{
  options.services.voomBackup = {
    enable = lib.mkEnableOption "daily file backups of running MacOS Voom guests";
    volume = lib.mkOption {
      type = lib.types.str;
      description = "Backup volume under /Volumes. The job fails unless it is mounted.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      description = "Path to the local Restic repository on the backup volume.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/restic/voom-password";
      description = "Repository password file, readable by the primary user.";
    };
    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.ssh/id_ed25519_voom_read";
      description = "SSH private key without a passphrase. Its public key must match userInfo.voomReadKey.";
    };
    stagingDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${home}/Library/Caches/voom-backup";
      description = "Dedicated directory for rsync copies, kept between runs and accessible only to the primary user. Must not overlap the repository. Existing guest directories require a .voom-backup-owned marker.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = systemType != "vm";
        message = "Enable services.voomBackup on the Voom host.";
      }
      {
        assertion = lib.hasPrefix "/Volumes/" cfg.volume && lib.hasPrefix "${cfg.volume}/" cfg.repository;
        message = "Set services.voomBackup.volume to a mounted /Volumes path and repository to a path within it.";
      }
      {
        assertion = (userInfo.voomReadKey or "") != "";
        message = "Set userInfo.voomReadKey and rebuild the MacOS guests before enabling Voom backups.";
      }
    ];
    environment.systemPackages = [
      backup
      restic
    ];
    launchd.user.agents.voom-backup = {
      environment.HOME = home;
      command = "${backup}/bin/voom-backup";
      serviceConfig = {
        StartCalendarInterval = [
          {
            Hour = 3;
            Minute = 0;
          }
        ];
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/voom-backup.log";
        StandardErrorPath = "${home}/Library/Logs/voom-backup.log";
      };
    };
  };
}
