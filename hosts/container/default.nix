{ config, inputs, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  keys = userInfo.sshKeys;
  vmHostnameFromMetadata = pkgs.writeShellScript "vm-hostname-from-metadata" ''
    set -eu

    for dev in /dev/vd? /dev/sd? /dev/xvd? /dev/nvme?n?; do
      [ -b "$dev" ] || continue

      data="$(${pkgs.coreutils}/bin/dd if="$dev" bs=1048576 count=1 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\000' || true)"
      case "$data" in
        MJRVMMETA1*|VOOMMETA1*)
          hostname="$(printf '%s\n' "$data" | ${pkgs.gnused}/bin/sed -n 's/^hostname=//p' | ${pkgs.coreutils}/bin/head -n1)"
          case "$hostname" in
            ""|*[^a-z0-9-]*|-*|*-)
              echo "Invalid VM metadata hostname: $hostname" >&2
              exit 1
              ;;
          esac
          ${pkgs.inetutils}/bin/hostname "$hostname"
          exit 0
        ;;
      esac
    done
  '';
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
in
{
  imports = [
    ../../modules/shared
    ../../modules/shared/caches
  ];

  networking.hostName = lib.mkDefault "nixos-container";

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

  systemd.services.vm-hostname-from-metadata = {
    description = "Set hostname from VM metadata disk";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    after = [ "systemd-udev-trigger.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = vmHostnameFromMetadata;
      RemainAfterExit = true;
    };
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

  nix = {
    settings.allowed-users = [ "${user}" ];
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
    gitFull
    inetutils
    iproute2
    jq
    util-linux
    ghostty.terminfo
  ];

  system.stateVersion = "24.11";
}
