{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.voomAgentVault;
  agentVaultPackage = pkgs.callPackage ../../packages/agent-vault.nix { };
  managerPackage = pkgs.callPackage ../../packages/voom-agent-vault { };
  chain = "VOOM_AGENT_VAULT";
  configFile = pkgs.writeText "voom-agent-vault-config.json" (
    builtins.toJSON {
      agentVault = lib.getExe agentVaultPackage;
      agentVaultVersion = "0.39.3";
      assignments = cfg.assignments;
      address = "http://127.0.0.1:${toString cfg.managementPort}";
      bridgeUnit = "voom-agent-vault-bridge.service";
      caPath = cfg.publicCAPath;
      firewallFreshnessSeconds = cfg.firewallFreshnessSeconds;
      firewallStatus = "/run/voom-agent-vault-firewall/status.json";
      haproxy = lib.getExe pkgs.haproxy;
      operationTimeoutSeconds = cfg.operationTimeoutSeconds;
      proxyAddress = "127.0.0.1:${toString cfg.proxyPort}";
      runtimeDir = cfg.runtimeDirectory;
      stateDir = cfg.stateDirectory;
      voom = lib.getExe' pkgs.voom "voom";
    }
  );
  dnsRules =
    tool: family:
    lib.concatMapStringsSep "\n" (
      address:
      let
        isV6 = lib.hasInfix ":" address;
      in
      lib.optionalString (isV6 == (family == 6)) ''
        ${tool} -w -t filter -A ${chain} -d ${lib.escapeShellArg address} -p udp --dport 53 -j ACCEPT
        ${tool} -w -t filter -A ${chain} -d ${lib.escapeShellArg address} -p tcp --dport 53 -j ACCEPT
      ''
    ) cfg.localDNSAddresses;
  installFirewall = pkgs.writeShellApplication {
    name = "voom-agent-vault-firewall-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      install_family() {
        local tool=$1
        "$tool" -w -t filter -N ${chain} 2>/dev/null || true
        "$tool" -w -t filter -F ${chain}
        "$tool" -w -t filter -A ${chain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        if [[ $tool == *ip6tables ]]; then
          :
          ${dnsRules "\"$tool\"" 6}
        else
          :
          ${dnsRules "\"$tool\"" 4}
        fi
        "$tool" -w -t filter -A ${chain} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j REJECT
        "$tool" -w -t filter -A ${chain} -j RETURN
        while "$tool" -w -t filter -C OUTPUT -m owner --uid-owner agent-vault -j ${chain} 2>/dev/null; do
          "$tool" -w -t filter -D OUTPUT -m owner --uid-owner agent-vault -j ${chain}
        done
        "$tool" -w -t filter -I OUTPUT 1 -m owner --uid-owner agent-vault -j ${chain}
      }

      install_family ${pkgs.iptables}/bin/iptables
      install_family ${pkgs.iptables}/bin/ip6tables
    '';
  };
  removeFirewall = pkgs.writeShellApplication {
    name = "voom-agent-vault-firewall-remove";
    text = ''
      remove_family() {
        local tool=$1
        while "$tool" -w -t filter -C OUTPUT -m owner --uid-owner agent-vault -j ${chain} 2>/dev/null; do
          "$tool" -w -t filter -D OUTPUT -m owner --uid-owner agent-vault -j ${chain}
        done
        "$tool" -w -t filter -F ${chain} 2>/dev/null || true
        "$tool" -w -t filter -X ${chain} 2>/dev/null || true
      }

      remove_family ${pkgs.iptables}/bin/iptables
      remove_family ${pkgs.iptables}/bin/ip6tables
    '';
  };
  verifyFirewall = pkgs.writeShellApplication {
    name = "voom-agent-vault-firewall-verify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      verify_family() {
        local tool=$1
        local family=$2
        local uid first jump_count target_count expected_count chain_rule_count
        local -a rules chain_rules
        uid=$(id -u agent-vault)
        mapfile -t rules < <("$tool" -w -t filter -S OUTPUT | sed -n '/^-A OUTPUT /p')
        [[ ''${#rules[@]} -gt 0 ]] || {
          echo "$family OUTPUT has no rules" >&2
          return 1
        }
        first="''${rules[0]}"
        [[ $first == "-A OUTPUT -m owner --uid-owner $uid -j ${chain}" ]] || {
          echo "$family Agent Vault jump is not OUTPUT rule 1" >&2
          return 1
        }
        jump_count=$(printf '%s\n' "''${rules[@]}" | grep -Fxc -- "-A OUTPUT -m owner --uid-owner $uid -j ${chain}" || true)
        [[ $jump_count -eq 1 ]] || {
          echo "$family Agent Vault OUTPUT jump count is $jump_count" >&2
          return 1
        }
        target_count=$(printf '%s\n' "''${rules[@]}" | grep -Ec -- " -j ${chain}$" || true)
        [[ $target_count -eq 1 ]] || {
          echo "$family ${chain} target count is $target_count" >&2
          return 1
        }
        "$tool" -w -t filter -C ${chain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        if [[ $family == IPv6 ]]; then
          ${lib.concatMapStringsSep "\n" (
            address:
            lib.optionalString (lib.hasInfix ":" address) ''
              "$tool" -w -t filter -C ${chain} -d ${lib.escapeShellArg address} -p udp --dport 53 -j ACCEPT
              "$tool" -w -t filter -C ${chain} -d ${lib.escapeShellArg address} -p tcp --dport 53 -j ACCEPT
            ''
          ) cfg.localDNSAddresses}
          expected_count=$((4 + ${
            toString (2 * builtins.length (builtins.filter (lib.hasInfix ":") cfg.localDNSAddresses))
          }))
        else
          ${lib.concatMapStringsSep "\n" (
            address:
            lib.optionalString (!lib.hasInfix ":" address) ''
              "$tool" -w -t filter -C ${chain} -d ${lib.escapeShellArg address} -p udp --dport 53 -j ACCEPT
              "$tool" -w -t filter -C ${chain} -d ${lib.escapeShellArg address} -p tcp --dport 53 -j ACCEPT
            ''
          ) cfg.localDNSAddresses}
          expected_count=$((4 + ${
            toString (
              2 * builtins.length (builtins.filter (address: !lib.hasInfix ":" address) cfg.localDNSAddresses)
            )
          }))
        fi
        "$tool" -w -t filter -C ${chain} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j REJECT
        "$tool" -w -t filter -C ${chain} -j RETURN
        [[ $("$tool" -w -t filter -S ${chain} | wc -l) -eq $expected_count ]] || {
          echo "$family ${chain} contains unexpected or duplicate rules" >&2
          return 1
        }
        mapfile -t chain_rules < <("$tool" -w -t filter -S ${chain} | sed -n '/^-A ${chain} /p')
        chain_rule_count=''${#chain_rules[@]}
        [[ $chain_rule_count -ge 3 ]] || {
          echo "$family ${chain} is incomplete" >&2
          return 1
        }
        [[ ''${chain_rules[0]} == "-A ${chain} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" || \
          ''${chain_rules[0]} == "-A ${chain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" ]] || {
          echo "$family ${chain} does not begin with the established-connection rule" >&2
          return 1
        }
        [[ ''${chain_rules[chain_rule_count - 2]} == "-A ${chain} -m conntrack --ctstate NEW -m addrtype --dst-type LOCAL -j REJECT"* ]] || {
          echo "$family ${chain} does not reject new local traffic before returning" >&2
          return 1
        }
        [[ ''${chain_rules[chain_rule_count - 1]} == "-A ${chain} -j RETURN" ]] || {
          echo "$family ${chain} does not end with RETURN" >&2
          return 1
        }
      }

      verify_family ${pkgs.iptables}/bin/iptables IPv4
      verify_family ${pkgs.iptables}/bin/ip6tables IPv6
    '';
  };
  publishFirewallStatus = pkgs.writeShellApplication {
    name = "voom-agent-vault-firewall-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      output=""
      if output=$(
        {
          ${lib.getExe verifyFirewall} &&
          ${lib.getExe verifyResolver}
        } 2>&1
      ); then
        ok=true
        rc=0
      else
        ok=false
        rc=1
      fi
      temporary=$(mktemp /run/voom-agent-vault-firewall/.status.XXXXXX)
      jq -n \
        --argjson ok "$ok" \
        --argjson timestamp "$(date +%s)" \
        --arg error "$output" \
        '{schemaVersion: 1, ok: $ok, timestamp: $timestamp, error: $error}' >"$temporary"
      chmod 0644 "$temporary"
      mv "$temporary" /run/voom-agent-vault-firewall/status.json
      if [[ $rc -ne 0 ]]; then
        systemctl stop agent-vault.service
      fi
      exit "$rc"
    '';
  };
  createMasterPassword = pkgs.writeShellApplication {
    name = "voom-agent-vault-create-master-password";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    text = ''
      destination=${lib.escapeShellArg cfg.masterPasswordFile}
      if [[ -s "$destination" ]]; then
        exit 0
      fi
      install -d -m 0700 "$(dirname "$destination")"
      temporary=$(mktemp "$(dirname "$destination")/.master-password.XXXXXX")
      openssl rand -base64 48 >"$temporary"
      chmod 0400 "$temporary"
      mv "$temporary" "$destination"
    '';
  };
  startAgentVault = pkgs.writeShellApplication {
    name = "voom-agent-vault-server-start";
    text = ''
      exec ${lib.getExe agentVaultPackage} --telemetry=false server \
        --host 127.0.0.1 \
        --port ${toString cfg.managementPort} \
        --mitm-port ${toString cfg.proxyPort} \
        --log-level info \
        --password-stdin <"$CREDENTIALS_DIRECTORY/master-password"
    '';
  };
  publishCA = pkgs.writeShellApplication {
    name = "voom-agent-vault-publish-ca";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      source=/var/lib/agent-vault/.agent-vault/ca/ca.crt.pem
      destination=${lib.escapeShellArg cfg.publicCAPath}
      for _ in $(seq 1 50); do
        if [[ -s "$source" ]]; then
          temporary=$(mktemp "$destination.XXXXXX")
          install -m 0644 "$source" "$temporary"
          mv "$temporary" "$destination"
          exit 0
        fi
        sleep 0.1
      done
      echo "Agent Vault CA was not available after startup" >&2
      exit 1
    '';
  };
  verifyResolver = pkgs.writeShellApplication {
    name = "voom-agent-vault-resolver-verify";
    runtimeInputs = [ pkgs.gawk ];
    text = ''
      allowed=( ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.localDNSAddresses} )
      is_allowed() {
        local candidate=$1
        local configured
        for configured in "''${allowed[@]}"; do
          if [[ $candidate == "$configured" ]]; then
            return 0
          fi
        done
        return 1
      }

      while read -r address; do
        if [[ $address == *:* ]]; then
          route=$(${pkgs.iproute2}/bin/ip -6 route get "$address" 2>/dev/null || true)
        else
          route=$(${pkgs.iproute2}/bin/ip route get "$address" 2>/dev/null || true)
        fi
        if [[ $route == local\ * ]] && ! is_allowed "$address"; then
          echo "host-local resolver $address is not listed in services.voomAgentVault.localDNSAddresses" >&2
          exit 1
        fi
      done < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
    '';
  };
  snapshotDatabase = pkgs.writeShellApplication {
    name = "voom-agent-vault-snapshot-database";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.sqlite
    ];
    text = ''
      source=/var/lib/agent-vault/.agent-vault/agent-vault.db
      destination=/var/cache/agent-vault-backup/agent-vault.db
      if [[ ! -r "$source" ]]; then
        echo "Agent Vault database is unavailable" >&2
        exit 1
      fi
      temporary="$destination.tmp"
      sqlite3 "$source" ".backup '$temporary'"
      chmod 0600 "$temporary"
      mv "$temporary" "$destination"
      install -d -m 0700 /var/cache/agent-vault-backup/ca
      install -m 0600 /var/lib/agent-vault/.agent-vault/ca/ca.crt.pem \
        /var/cache/agent-vault-backup/ca/ca.crt.pem
      install -m 0600 /var/lib/agent-vault/.agent-vault/ca/ca.key.enc \
        /var/cache/agent-vault-backup/ca/ca.key.enc
    '';
  };
in
{
  options.services.voomAgentVault = {
    enable = lib.mkEnableOption "the Agent Vault broker for Voom guests";
    user = lib.mkOption {
      type = lib.types.str;
      description = "User that owns the Voom state and bridge.";
    };
    assignments = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Exact Voom VM name to Agent Vault vault mapping.";
    };
    masterPasswordFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/voom-agent-vault-secrets/master-password";
      description = "Root-only file used as the Agent Vault systemd credential.";
    };
    publicCAPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/voom-agent-vault-public/ca.pem";
      readOnly = true;
    };
    managementPort = lib.mkOption {
      type = lib.types.port;
      default = 14321;
    };
    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 14322;
    };
    localDNSAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Exact host-local resolver addresses allowed only on TCP and UDP port 53.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.local/state/voom-agent-vault";
      description = "Persistent attachment, hold, and token state for the Voom owner.";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/run/user/%U/voom-agent-vault";
      description = "Private runtime directory; %U expands to the Voom owner's numeric UID.";
    };
    operationTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Timeout for Agent Vault and Voom operations; this must exceed Voom's fail-closed runtime shutdown window.";
    };
    firewallFreshnessSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.firewall.enable;
        message = "services.voomAgentVault requires the NixOS firewall.";
      }
      {
        assertion = config.networking.firewall.backend == "iptables";
        message = "services.voomAgentVault requires the iptables firewall backend.";
      }
      {
        assertion = !config.networking.nftables.enable;
        message = "services.voomAgentVault is incompatible with networking.nftables.enable.";
      }
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.voomAgentVault.user must name a declared local user.";
      }
      {
        assertion = cfg.managementPort != cfg.proxyPort;
        message = "Agent Vault management and proxy ports must differ.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.stateDirectory && lib.hasPrefix "/" cfg.runtimeDirectory;
        message = "Agent Vault state and runtime directories must be absolute paths.";
      }
    ];

    environment.etc."voom-agent-vault/config.json".source = configFile;
    environment.systemPackages = [
      agentVaultPackage
      managerPackage
    ];
    environment.variables.AGENT_VAULT_TELEMETRY = "false";

    users.groups.agent-vault = { };
    users.users.agent-vault = {
      isSystemUser = true;
      group = "agent-vault";
      home = "/var/lib/agent-vault";
    };
    users.users.${cfg.user}.linger = true;

    systemd.tmpfiles.rules = [
      "d /var/lib/voom-agent-vault-secrets 0700 root root -"
      "d /var/lib/voom-agent-vault-public 0755 agent-vault agent-vault -"
      "d /var/cache/agent-vault-backup 0700 agent-vault agent-vault -"
      "d /run/voom-agent-vault-firewall 0755 root root -"
    ];

    systemd.services.voom-agent-vault-master-password = {
      description = "Create the Agent Vault master-password credential";
      requiredBy = [ "agent-vault.service" ];
      before = [ "agent-vault.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe createMasterPassword;
        UMask = "0077";
      };
    };

    systemd.services.voom-agent-vault-resolver-check = {
      description = "Verify Agent Vault resolver access";
      wants = [ "network-online.target" ];
      before = [ "agent-vault.service" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe verifyResolver;
      };
    };

    systemd.services.voom-agent-vault-firewall = {
      description = "Restrict Agent Vault connections to host-local addresses";
      wantedBy = [ "multi-user.target" ];
      wants = [ "agent-vault.service" ];
      requires = [ "firewall.service" ];
      bindsTo = [ "firewall.service" ];
      partOf = [ "firewall.service" ];
      after = [ "firewall.service" ];
      before = [ "agent-vault.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe installFirewall;
        ExecStartPost = lib.getExe verifyFirewall;
        ExecStop = lib.getExe removeFirewall;
      };
    };

    systemd.services.voom-agent-vault-firewall-failed = {
      description = "Stop Agent Vault after a firewall verification failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl stop agent-vault.service";
      };
    };

    systemd.services.voom-agent-vault-firewall-check = {
      description = "Verify the Agent Vault firewall boundary";
      after = [ "voom-agent-vault-firewall.service" ];
      onFailure = [ "voom-agent-vault-firewall-failed.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe publishFirewallStatus;
      };
    };

    systemd.timers.voom-agent-vault-firewall-check = {
      description = "Periodic Agent Vault firewall verification";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
        Unit = "voom-agent-vault-firewall-check.service";
      };
    };

    systemd.services.agent-vault = {
      description = "Agent Vault credential broker";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "firewall.service"
        "voom-agent-vault-firewall.service"
        "voom-agent-vault-master-password.service"
        "voom-agent-vault-resolver-check.service"
      ];
      bindsTo = [
        "firewall.service"
        "voom-agent-vault-firewall.service"
      ];
      partOf = [
        "firewall.service"
        "voom-agent-vault-firewall.service"
      ];
      after = [
        "firewall.service"
        "voom-agent-vault-firewall.service"
        "voom-agent-vault-master-password.service"
        "voom-agent-vault-resolver-check.service"
      ];
      serviceConfig = {
        Type = "simple";
        User = "agent-vault";
        Group = "agent-vault";
        StateDirectory = "agent-vault";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/agent-vault";
        LoadCredential = "master-password:${cfg.masterPasswordFile}";
        ExecStartPre = [
          "+${lib.getExe verifyFirewall}"
        ];
        ExecStart = lib.getExe startAgentVault;
        ExecStartPost = lib.getExe publishCA;
        Restart = "on-failure";
        RestartSec = "2s";
        LimitCORE = 0;
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        ReadWritePaths = [
          "/var/lib/agent-vault"
          "/var/lib/voom-agent-vault-public"
        ];
      };
      environment = {
        HOME = "/var/lib/agent-vault";
        AGENT_VAULT_ADDR = "http://127.0.0.1:${toString cfg.managementPort}";
        AGENT_VAULT_ALLOW_PRIVATE_RANGES = "false";
        AGENT_VAULT_NETWORK_ALLOWLIST = "";
        AGENT_VAULT_LOGS_MAX_AGE_HOURS = "168";
        AGENT_VAULT_LOGS_MAX_ROWS_PER_VAULT = "10000";
        AGENT_VAULT_LOGS_RETENTION_LOCK = "true";
        AGENT_VAULT_RATELIMIT_LOCK = "true";
        AGENT_VAULT_RATELIMIT_PROFILE = "default";
        AGENT_VAULT_TELEMETRY = "false";
      };
    };

    systemd.services.voom-agent-vault-database-snapshot = {
      description = "Create a consistent Agent Vault SQLite snapshot";
      after = [ "agent-vault.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "agent-vault";
        Group = "agent-vault";
        ExecStart = lib.getExe snapshotDatabase;
        UMask = "0077";
      };
    };

    systemd.timers.voom-agent-vault-database-snapshot = {
      description = "Daily Agent Vault SQLite snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };

    systemd.user.services.voom-agent-vault-bridge-render = {
      description = "Render the Voom Agent Vault bridge configuration";
      before = [ "voom-agent-vault-bridge.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe managerPackage} --config /etc/voom-agent-vault/config.json render-bridge";
        UMask = "0077";
      };
      unitConfig.ConditionUser = cfg.user;
    };

    systemd.user.services.voom-agent-vault-bridge = {
      description = "Voom Agent Vault identity bridge";
      wantedBy = [ "default.target" ];
      requires = [ "voom-agent-vault-bridge-render.service" ];
      after = [ "voom-agent-vault-bridge-render.service" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        Type = "notify-reload";
        NotifyAccess = "main";
        ExecStart = "${lib.getExe pkgs.haproxy} -Ws -f ${cfg.runtimeDirectory}/current/haproxy.cfg -p ${cfg.runtimeDirectory}/haproxy.pid";
        ReloadSignal = "SIGUSR2";
        Restart = "on-failure";
        RestartSec = "2s";
        KillMode = "mixed";
        LimitCORE = 0;
        UMask = "0077";
        ProtectHome = "tmpfs";
        BindPaths = [ cfg.runtimeDirectory ];
        BindReadOnlyPaths = [ "%t/systemd/notify" ];
        ProtectSystem = "strict";
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
