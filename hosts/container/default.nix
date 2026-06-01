{ config, inputs, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  keys = userInfo.sshKeys;
  voomPortfwd = pkgs.writeShellScript "voom-portfwd" ''
    set -u

    output="''${VOOM_PORTFWD_OUTPUT:-/run/voom/ports.json}"
    interval="''${VOOM_PORTFWD_INTERVAL:-2}"
    dir="$(${pkgs.coreutils}/bin/dirname "$output")"

    while true; do
      if ${pkgs.util-linux}/bin/mountpoint -q "$dir"; then
        tmp="$output.tmp.$$"
        generated_at="$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        listeners="$(
          ${pkgs.iproute2}/bin/ss -tlnpH 2>/dev/null \
            | ${pkgs.gawk}/bin/awk '
                function json_escape(s) {
                  gsub(/\\/, "\\\\", s)
                  gsub(/"/, "\\\"", s)
                  return s
                }
                function emit(local, proc, addr, port, pid, name, n) {
                  if (local ~ /^\[/) {
                    n = split(local, parts, "]:")
                    addr = substr(parts[1], 2)
                    port = parts[2]
                  } else {
                    n = split(local, parts, ":")
                    port = parts[n]
                    addr = substr(local, 1, length(local) - length(port) - 1)
                  }
                  if (addr == "") addr = "*"

                  pid = ""
                  name = ""
                  if (match(proc, /pid=[0-9]+/)) pid = substr(proc, RSTART + 4, RLENGTH - 4)
                  if (match(proc, /"[^"]+"/)) name = substr(proc, RSTART + 1, RLENGTH - 2)

                  printf "{\"proto\":\"tcp\",\"addr\":\"%s\",\"port\":%s", json_escape(addr), port
                  if (pid != "") printf ",\"pid\":%s", pid
                  if (name != "") printf ",\"process\":\"%s\"", json_escape(name)
                  printf "}\n"
                }
                $1 == "LISTEN" { emit($4, $0) }
              ' \
            | ${pkgs.jq}/bin/jq -s '.'
        )"

        if ${pkgs.jq}/bin/jq -n \
          --arg generatedAt "$generated_at" \
          --argjson listeners "$listeners" \
          '{schemaVersion: 1, generatedAt: $generatedAt, listeners: $listeners}' > "$tmp"; then
          ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
          ${pkgs.coreutils}/bin/mv "$tmp" "$output"
        else
          ${pkgs.coreutils}/bin/rm -f "$tmp"
        fi
      fi

      ${pkgs.coreutils}/bin/sleep "$interval"
    done
  '';
  voomMountShares = pkgs.writeShellScript "voom-mount-shares" ''
    set -euo pipefail

    mounts_file="''${VOOM_MOUNTS_FILE:-/run/voom/mounts.json}"

    for i in $(seq 1 10); do
      [ -f "$mounts_file" ] && break
      ${pkgs.coreutils}/bin/sleep 1
    done
    [ -f "$mounts_file" ] || exit 0

    ${pkgs.jq}/bin/jq -r '
      .[] | [
        (.tag // ""),
        (.guestPath // ""),
        (if (.readonly // false) then "ro" else "rw" end)
      ] | @tsv
    ' "$mounts_file" | while IFS=$'\t' read -r tag guest_path mode; do
      [ -n "$tag" ] || continue
      [ -n "$guest_path" ] || continue

      ${pkgs.coreutils}/bin/mkdir -p "$guest_path"
      if ${pkgs.util-linux}/bin/mountpoint -q "$guest_path" 2>/dev/null; then
        continue
      fi

      opts=()
      if [ "$mode" = "ro" ]; then
        opts=(-o ro)
      fi

      ${pkgs.util-linux}/bin/mount -t virtiofs "''${opts[@]}" "$tag" "$guest_path"
    done
  '';
  voomSetHostname = pkgs.writeShellScript "voom-set-hostname" ''
    set -euo pipefail

    metadata_file="''${VOOM_METADATA_FILE:-/run/voom/metadata.json}"
    [ -f "$metadata_file" ] || exit 0

    hostname="$(${pkgs.jq}/bin/jq -er '.hostname | strings | select(length > 0 and length <= 63)' "$metadata_file")"
    case "$hostname" in
      *[^a-zA-Z0-9_-]*|-*|_*|*-|*_)
        echo "Invalid voom hostname: $hostname" >&2
        exit 1
        ;;
    esac

    ${pkgs.inetutils}/bin/hostname "$hostname"
  '';
in
{
  imports = [
    ../../modules/shared
    ../../modules/shared/caches
  ];

  networking.hostName = lib.mkDefault "nixos-container";

  # When running via voom, the guest sits behind gvproxy NAT; nothing can reach
  # the guest except through explicit host-side forwards, which voom installs
  # explicitly.
  networking.firewall.enable = lib.mkDefault false;

  boot.kernelModules = [ "virtiofs" ];

  fileSystems."/run/voom" = {
    device = "voom-control";
    fsType = "virtiofs";
    noCheck = true;
    options = [ "nofail" ];
  };

  systemd.tmpfiles.rules = [
    "d /run/voom 0755 root root -"
  ];

  services.cloud-init = {
    enable = true;
    settings = {
      datasource_list = [ "NoCloud" "None" ];
      preserve_hostname = false;
      system_info.network.renderers = [ "networkd" ];
    };
  };

  # Bring the guest NIC up via DHCP, independently of cloud-init's network
  # stage. gvproxy hands out 192.168.127.2 on the virtio-net link; without an
  # active DHCP client the link stays down and any host-side forward to that IP
  # fails with "no route to host". This matches both legacy (eth*) and
  # predictable (en*) interface names so it works under both QEMU and vfkit.
  systemd.network.networks."10-vm-dhcp" = {
    matchConfig.Name = "en* eth*";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  systemd.services.voom-portfwd = {
    description = "Report guest TCP listeners to voom";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "run-voom.mount" ];
    serviceConfig = {
      ExecStart = voomPortfwd;
      Restart = "always";
      RestartSec = "2s";
    };
  };

  systemd.services.voom-mount-shares = {
    description = "Mount voom-declared virtiofs shares";
    wantedBy = [ "multi-user.target" ];
    wants = [ "run-voom.mount" ];
    after = [ "run-voom.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = voomMountShares;
      RemainAfterExit = true;
    };
  };

  systemd.services.voom-set-hostname = {
    description = "Set hostname from voom metadata";
    wantedBy = [ "multi-user.target" ];
    wants = [ "run-voom.mount" ];
    after = [ "run-voom.mount" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = voomSetHostname;
      RemainAfterExit = true;
    };
  };

  nix = {
    settings.allowed-users = [ "${user}" ];
    settings.trusted-users = [ "@wheel" "${user}" ];
    package = pkgs.nixVersions.latest;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  programs = {
    gnupg.agent.enable = true;
    fish.enable = true;
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users = {
    ${user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = keys;
    };

    root = {
      openssh.authorizedKeys.keys = keys;
    };
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
    extraRules = [{
      commands = [
       {
         command = "${pkgs.systemd}/bin/reboot";
         options = [ "NOPASSWD" ];
        }
      ];
      groups = [ "wheel" ];
    }];
  };

  environment.systemPackages = with pkgs; [
    cloud-init
    gitFull
    inetutils
    iproute2
    jq
    util-linux
    ghostty.terminfo
  ];

  system.stateVersion = "24.11";
}
