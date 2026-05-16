{ config, inputs, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  keys = userInfo.sshKeys;
  vmHostnameFromMetadata = pkgs.writeShellScript "vm-hostname-from-metadata" ''
    set -eu

    marker="MJRVMMETA1"
    for dev in /dev/vd? /dev/sd? /dev/xvd? /dev/nvme?n?; do
      [ -b "$dev" ] || continue

      data="$(${pkgs.coreutils}/bin/dd if="$dev" bs=4096 count=1 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\000' || true)"
      case "$data" in
        "$marker"*)
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
in
{
  imports = [
    ../../modules/shared
    ../../modules/shared/caches
  ];

  networking.hostName = lib.mkDefault "nixos-container";

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
    ghostty.terminfo
  ];

  system.stateVersion = "24.11";
}
