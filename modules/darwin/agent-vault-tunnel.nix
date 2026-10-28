{
  config,
  lib,
  pkgs,
  systemType,
  ...
}:
let
  cfg = config.services.agentVaultTunnel;
  package = pkgs.callPackage ../../packages/agent-vault-tunnel { };
  settings = pkgs.writeText "agent-vault-tunnel.json" (
    builtins.toJSON {
      inherit (cfg)
        listenAddress
        port
        host
        identityFile
        knownHostsFile
        ;
      pfctl = "/sbin/pfctl";
      ssh = lib.getExe pkgs.openssh;
    }
  );
in
{
  options.services.agentVaultTunnel = {
    enable = lib.mkEnableOption "the shared Agent Vault tunnel for macOS guests";
    host = lib.mkOption {
      type = lib.types.str;
      description = "Linux host running the shared Agent Vault proxy.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+";
      description = "Stable LAN IPv4 address of the Mac host.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3128;
    };
    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/agent-vault-tunnel/id_ed25519";
      description = "Root-owned dedicated SSH private key on the Mac host.";
    };
    knownHostsFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/agent-vault-tunnel/known_hosts";
      description = "Root-owned file pinning the Linux host's verified SSH host key.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = systemType != "vm";
        message = "Enable agentVaultTunnel on the Mac host.";
      }
      {
        assertion = cfg.port >= 1024;
        message = "Use an unprivileged Agent Vault proxy port.";
      }
    ];
    launchd.daemons.agent-vault-tunnel = {
      command = "${lib.getExe package} ${settings}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 15;
        ExitTimeOut = 15;
        StandardOutPath = "/var/log/agent-vault-tunnel.log";
        StandardErrorPath = "/var/log/agent-vault-tunnel.log";
      };
    };
  };
}
