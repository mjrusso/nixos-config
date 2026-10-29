{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.voomAgentVault.sharedProxy;
  directory = "/run/agent-vault-shared-proxy";
  stateDirectory = "/var/lib/agent-vault-shared-proxy";
  proxyConfig = pkgs.writeText "agent-vault-shared-proxy.cfg" ''
    global
      log stderr format raw local0
    defaults
      mode http
      log global
      timeout connect 10s
      timeout client 15m
      timeout server 15m
      timeout tunnel 15m
      log-format shared-proxy\ identity=%[var(txn.identity)]\ status=%ST\ bytes=%B
    listen macos_guests
      bind ${directory}/proxy.sock mode 660
      acl one_auth req.hdr_cnt(Proxy-Authorization) eq 1
      acl basic_auth req.hdr(Proxy-Authorization) -m reg -i '^Basic +[A-Za-z0-9+/]+={0,2}$'
      http-request return status 407 hdr Proxy-Authenticate 'Basic realm="Agent Vault"' unless one_auth basic_auth
      http-request set-var(txn.access) 'req.hdr(Proxy-Authorization),word(2, ),map(${directory}/access.map)'
      http-request return status 407 hdr Proxy-Authenticate 'Basic realm="Agent Vault"' unless { var(txn.access) -m found }
      http-request set-var(txn.identity) var(txn.access),field(1,|)
      http-request set-header Proxy-Authorization "Basic %[var(txn.access),field(2,|)]"
      http-reuse never
      server agent-vault 127.0.0.1:${toString config.services.voomAgentVault.proxyPort}
  '';
  settings = pkgs.writeText "agent-vault-access.json" (
    builtins.toJSON {
      inherit (cfg) vaults identities;
      inherit stateDirectory;
      mapFile = "${directory}/access.map";
      haproxy = lib.getExe pkgs.haproxy;
      haproxyConfig = proxyConfig;
      systemctl = "${pkgs.systemd}/bin/systemctl";
    }
  );
  access = pkgs.writeShellApplication {
    name = "agent-vault-access";
    text = ''
      exec ${lib.getExe pkgs.python3} ${../../packages/agent-vault-access.py} ${settings} "$@"
    '';
  };
in
{
  options.services.voomAgentVault.sharedProxy = {
    enable = lib.mkEnableOption "a shared Agent Vault socket for remote macOS guests";
    vaults = lib.mkOption {
      default = { };
      description = "Vault profiles and their separate proxy-only Agent Vault tokens.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }: {
            options.tokenFile = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/voom-agent-vault-secrets/macos-${name}-token";
              description = "Root-owned runtime file containing this vault's proxy-only agent token.";
            };
          }
        )
      );
    };
    identities = lib.mkOption {
      default = { };
      description = "Proxy access identities; multiple guests may share one identity.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }: {
            options = {
              vault = lib.mkOption {
                type = lib.types.enum (builtins.attrNames cfg.vaults);
                description = "Vault selected after this identity authenticates.";
              };
              passwordFile = lib.mkOption {
                type = lib.types.str;
                default = "${stateDirectory}/passwords/${name}";
                description = "Root-owned runtime file containing the proxy password.";
              };
            };
          }
        )
      );
    };
    authorizedKeysFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-vault-shared-proxy/authorized_keys";
      description = "Root-owned runtime authorized_keys file for the Mac host's dedicated SSH key.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.voomAgentVault.enable;
        message = "The shared proxy requires services.voomAgentVault.enable.";
      }
      {
        assertion = lib.all (lib.hasPrefix "/") (
          [ cfg.authorizedKeysFile ]
          ++ map (v: v.tokenFile) (builtins.attrValues cfg.vaults)
          ++ map (v: v.passwordFile) (builtins.attrValues cfg.identities)
        );
        message = "Shared proxy credential paths must be absolute.";
      }
      {
        assertion =
          lib.all (name: builtins.match "[a-zA-Z0-9_-]+" name != null) (builtins.attrNames cfg.identities)
          && lib.all (name: builtins.match "[a-zA-Z0-9-]+" name != null) (builtins.attrNames cfg.vaults);
        message = "Use letters, numbers, hyphens (and underscores for identities) in shared proxy names.";
      }
    ];
    users.groups.agent-vault-tunnel = { };
    users.users.agent-vault-tunnel = {
      isSystemUser = true;
      group = "agent-vault-tunnel";
    };
    users.users.agent-vault-shared-proxy = {
      isSystemUser = true;
      group = "agent-vault-tunnel";
    };
    systemd.tmpfiles.rules = [
      "d ${stateDirectory} 0755 root root -"
      "d ${stateDirectory}/disabled 0755 root root -"
      "d ${stateDirectory}/passwords 0700 root root -"
    ];
    environment.systemPackages = [ access ];
    services.openssh.enable = true;
    # Streamlocal forwards share OpenSSH's PermitOpen table. Brackets let its
    # host parser accept a socket path, which cannot match a TCP destination.
    services.openssh.extraConfig = ''
      Match User agent-vault-tunnel
        AuthorizedKeysFile ${cfg.authorizedKeysFile}
        AuthenticationMethods publickey
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        AllowTcpForwarding local
        PermitOpen [${directory}/proxy.sock]:*
        AllowStreamLocalForwarding local
        AllowAgentForwarding no
        X11Forwarding no
        PermitTunnel no
        PermitTTY no
        MaxSessions 0
      Match all
    '';
    systemd.services.agent-vault-shared-proxy = {
      description = "Authenticated Agent Vault access for macOS guests";
      wantedBy = [
        "multi-user.target"
        "agent-vault.service"
      ];
      requires = [ "agent-vault.service" ];
      after = [ "agent-vault.service" ];
      partOf = [ "agent-vault.service" ];
      serviceConfig = {
        User = "agent-vault-shared-proxy";
        Group = "agent-vault-tunnel";
        RuntimeDirectory = "agent-vault-shared-proxy";
        RuntimeDirectoryMode = "0750";
        LoadCredential =
          lib.mapAttrsToList (name: vault: "vault-${name}:${vault.tokenFile}") cfg.vaults
          ++ lib.mapAttrsToList (name: identity: "password-${name}:${identity.passwordFile}") cfg.identities;
        ExecStart = "${lib.getExe access} _serve";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        LimitCORE = 0;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
      };
    };
  };
}
