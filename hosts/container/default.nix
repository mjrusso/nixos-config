{ config, voom, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  keys = userInfo.sshKeys;
  # Note that sudo is required to make root-owned state readable when backing
  # up. The `from=` address is gvproxy's gateway (i.e., the address a guest
  # sees for a connection originating on the host).
  #
  # We use rsync instead of sftp, because sshfs returns EPERM on readlink, so
  # every symlink would be stored without its target.
  voomReadFrom = let src = userInfo.voomReadKeySource or ""; in
    lib.optionalString (src != "") '',from="${src}"'';
  backupKeys = lib.optional ((userInfo.voomReadKey or "") != "")
    ''restrict,command="sudo --preserve-env=SSH_ORIGINAL_COMMAND ${pkgs.rrsync}/bin/rrsync -ro /"${voomReadFrom} ${userInfo.voomReadKey}'';
  guestControl = voom.packages.${pkgs.stdenv.hostPlatform.system}.guest-control;

in
{
  imports = [
    ../../modules/shared
    ../../modules/shared/caches
    ../../modules/container/voom-egress.nix
    ../../modules/container/nvidia.nix
    ../../modules/nixos/desktop.nix
  ];

  networking.hostName = lib.mkDefault "nixos-container";
  networking.dhcpcd.extraConfig = ''
    nooption domain_name
    nooption domain_search
  '';

  # When running via voom, the guest sits behind gvproxy NAT; nothing can reach
  # the guest except through explicit host-side forwards, which voom installs
  # explicitly.
  networking.firewall.enable = lib.mkDefault false;

  boot.kernelModules = [ "virtiofs" "vmw_vsock_virtio_transport" "qemu_fw_cfg" ];

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

  systemd.services.voom-guest = {
    description = "Voom vsock guest control";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    path = [ pkgs.iproute2 pkgs.util-linux pkgs.inetutils ];
    environment.PYTHONPATH = "${guestControl}";
    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = "${pkgs.python3}/bin/python3 ${guestControl}/guest_linux.py";
      Restart = "always";
      RestartSec = "2s";
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
      AcceptEnv = [ "SYSTEM_APPEARANCE" ];
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users = {
    ${user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = keys ++ backupKeys;
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
