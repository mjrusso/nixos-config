{
  config,
  lib,
  userInfo,
  hostInfo,
  ...
}:
let
  cfg = config.services.hostBackup;
  user = userInfo.user;
  home = config.users.users.${user}.home;
  sshCommand =
    "ssh ${lib.escapeShellArg "${cfg.targetUser}@${cfg.target}"}"
    + " -i ${lib.escapeShellArg cfg.identityFile} -o IdentitiesOnly=yes -s sftp";
in
{
  options.services.hostBackup = {
    enable = lib.mkEnableOption "daily home-directory backups over SFTP";
    target = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "SSH host for the backup repository.";
    };
    targetUser = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = user;
      description = "SSH user on the backup target.";
    };
    repositoryPath = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Full repository path on the target, including any per-host directory.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/restic/password";
      description = "Repository password file, readable by the primary user.";
    };
    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.ssh/id_ed25519_restic";
      description = "SSH private key without a passphrase for the backup target.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.restic.backups.${hostInfo.nixosHostname} = {
      inherit user;
      initialize = true;
      repository = "sftp:${cfg.targetUser}@${cfg.target}:${cfg.repositoryPath}";
      passwordFile = cfg.passwordFile;
      paths = [
        home
      ]
      ++ lib.optionals config.services.voomAgentVault.enable [
        "/var/cache/agent-vault-backup"
      ];
      extraOptions = [ "sftp.command=${lib.escapeShellArg sshCommand}" ];
      exclude = [
        "${home}/.local/share/voom"
        "${home}/vms"
        "${home}/.cache"
        "${home}/.npm"
        "${home}/.cargo/registry"
        "${home}/.cargo/git"
        "${home}/.emacs.d.bak"
        "${home}/.config/gh"
        "${home}/.agent-vault/session.json"
        "**/node_modules"
        "**/.direnv"
        "**/result"
        "**/target/*"
      ]
      ++ lib.optionals config.services.voomAgentVault.enable [
        "${config.services.voomAgentVault.stateDirectory}/attachments/*/token"
      ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };

    systemd.services."restic-backups-${hostInfo.nixosHostname}" =
      lib.mkIf config.services.voomAgentVault.enable
        {
          wants = [ "voom-agent-vault-database-snapshot.service" ];
          after = [ "voom-agent-vault-database-snapshot.service" ];
          serviceConfig.SupplementaryGroups = [ "agent-vault-backup" ];
        };
  };
}
