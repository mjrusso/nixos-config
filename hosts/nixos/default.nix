{
  config,
  inputs,
  pkgs,
  lib,
  userInfo,
  hostInfo,
  ...
}:

let
  user = userInfo.user;
  keys = userInfo.sshKeys;
  backup = {
    enable = false;
    target = "";
    targetUser = user;
    repositoryPath = "";
    passwordFile = "/etc/restic/password";
    identityFile = "/home/${user}/.ssh/id_ed25519_restic";
    voomGuests = false;
    voomReadIdentityFile = "/home/${user}/.ssh/id_ed25519_voom_read";
  }
  // (hostInfo.nixosBackup or { });
in
{
  imports = [
    ../../modules/nixos/disk-config.nix
    ../../modules/nixos/tailscale.nix
    ../../modules/nixos/caddy.nix
    ../../modules/nixos/voom-agent-vault.nix
    ../../modules/nixos/vfio.nix
    ../../modules/nixos/desktop.nix
    ../../modules/shared
    ../../modules/shared/caches
  ];

  assertions = [
    {
      assertion = hostInfo.nixosHostname != "hostname";
      message = "Set hostInfo.nixosHostname in host-info.nix before building the NixOS host.";
    }
    {
      assertion = builtins.match "[0-9a-fA-F]{8}" hostInfo.nixosHostId != null;
      message = "Set hostInfo.nixosHostId in host-info.nix to exactly 8 hex characters before building the NixOS host.";
    }
    {
      assertion = hostInfo.nixosMainDisk != "/dev/disk/by-id/...";
      message = "Set hostInfo.nixosMainDisk in host-info.nix to the target drive's stable /dev/disk/by-id path before building the NixOS host.";
    }
    {
      assertion = !backup.enable || (backup.target != "" && backup.repositoryPath != "");
      message = "Set hostInfo.nixosBackup.target and hostInfo.nixosBackup.repositoryPath in host-info.nix when nixosBackup.enable is true.";
    }
    {
      assertion = !(backup.enable && backup.voomGuests) || (userInfo.voomReadKey or "") != "";
      message = "Set userInfo.voomReadKey in user-info.nix when nixosBackup.voomGuests is true, and rebuild the guests.";
    }
  ];

  # Use the systemd-boot EFI boot loader.
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 42;
        memtest86.enable = true;
      };
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems = [ "zfs" ];
    initrd.supportedFilesystems = [ "zfs" ];
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usbhid"
      "usb_storage"
      "sd_mod"
      "igb"
    ];
    initrd.systemd.enable = true;
    initrd.systemd.network.enable = true;
    initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        port = 2222;
        authorizedKeys = keys;
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
      };
    };
    # Uncomment for AMD GPU
    # initrd.kernelModules = [ "amdgpu" ];
    kernelParams = [
      "ip=dhcp"
      "zfs.zfs_arc_max=8589934592"
    ];
    kernelPackages = pkgs.linuxPackages;
    kernelModules = [ "uinput" ];
    tmp.useTmpfs = true;
    zfs.requestEncryptionCredentials = true;
    zfs.forceImportRoot = true;
    # qemu-user-static via binfmt_misc, so x86_64-linux hosts can build
    # aarch64-linux derivations. Registering the host's own system is an error
    # (nixpkgs asserts on it), so filter it out for native aarch64-linux hosts.
    binfmt.emulatedSystems = lib.filter (s: s != pkgs.stdenv.hostPlatform.system) [ "aarch64-linux" ];
  };

  # Set your time zone.
  time.timeZone = "America/New_York";

  networking = {
    hostName = hostInfo.nixosHostname;
    hostId =
      if builtins.match "[0-9a-fA-F]{8}" hostInfo.nixosHostId != null then
        hostInfo.nixosHostId
      else
        "00000000";
    hosts = hostInfo.nixosExtraHosts;
    useDHCP = lib.mkDefault true;
  };

  services.tailnetCaddy = (hostInfo.nixosTailnetCaddy or { }) // {
    syncUser = user;
  };

  virtualisation.vfioPassthrough = (hostInfo.nixosVfio or { }) // {
    inherit user;
  };

  # Turn on flag for proprietary software
  nix = {
    settings.allowed-users = [ "${user}" ];
    settings.trusted-users = [
      "@wheel"
      "${user}"
    ];
    package = pkgs.nixVersions.latest;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Manages keys and such
  programs = {
    gnupg.agent.enable = true;
    ssh = {
      startAgent = true;
    };

    # Needed for anything GTK related
    dconf.enable = true;

    # My shell
    fish.enable = true;
  };

  services = {
    localDesktop.enable = lib.mkDefault (hostInfo.nixosDesktop or true);
    # Let's be able to SSH into this machine
    openssh = {
      enable = true;
      settings = {
        AcceptEnv = [ "SYSTEM_APPEARANCE" ];
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
      };
    };

    # Sync state between machines.
    #
    # Devices and folders are managed imperatively through the web UI (see
    # README). `overrideDevices`/`overrideFolders = false` prevents changes
    # made in the web UI from being clobbered on rebuild. Connection options
    # stay declarative so the LAN-only policy survives a Syncthing state wipe.
    syncthing = {
      enable = true;
      openDefaultPorts = true;
      dataDir = "/home/${user}/.local/share/syncthing";
      configDir = "/home/${user}/.config/syncthing";
      user = "${user}";
      group = "users";
      guiAddress = "127.0.0.1:8384";
      overrideFolders = false;
      overrideDevices = false;

      settings.options = {
        globalAnnounceEnabled = false;
        localAnnounceEnabled = true;
        relaysEnabled = false;
        natEnabled = true;
      };
    };

    # Enable CUPS to print documents
    # printing.enable = true;
    # printing.drivers = [ pkgs.brlaser ]; # Brother printer driver

    gvfs.enable = true; # Mount, trash, and other functionalities
    tumbler.enable = true; # Thumbnail support for images

    restic.backups = lib.mkIf backup.enable {
      "${hostInfo.nixosHostname}" = {
        inherit user;
        initialize = true;
        repository = "sftp:${backup.targetUser}@${backup.target}:${backup.repositoryPath}/${hostInfo.nixosHostname}";
        passwordFile = backup.passwordFile;
        paths = [
          "/home/${user}"
        ]
        ++ lib.optionals config.services.voomAgentVault.enable [
          "/var/cache/agent-vault-backup"
        ];

        extraOptions = [
          "sftp.command='ssh ${backup.targetUser}@${backup.target} -i ${backup.identityFile} -o IdentitiesOnly=yes -s sftp'"
        ];

        exclude = [
          "/home/${user}/.local/share/voom"
          "/home/${user}/vms"
          "/home/${user}/.cache"
          "/home/${user}/.npm"
          "/home/${user}/.cargo/registry"
          "/home/${user}/.cargo/git"
          "/home/${user}/.emacs.d.bak"
          "/home/${user}/.config/gh"
          "/home/${user}/.agent-vault/session.json"
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
    };

    zfs = {
      autoScrub.enable = true;
      trim.enable = true;
      autoSnapshot.enable = true;
      zed.enableMail = false;
    };
    zfs.zed.settings = {
      ZED_DEBUG_LOG = "/var/log/zed.log";
    };
  };

  systemd.services."restic-backups-${hostInfo.nixosHostname}" =
    lib.mkIf (backup.enable && config.services.voomAgentVault.enable)
      {
        wants = [ "voom-agent-vault-database-snapshot.service" ];
        after = [ "voom-agent-vault-database-snapshot.service" ];
      };

  # Enable sound
  # sound.enable = true;

  # Video support
  hardware = {
    enableRedistributableFirmware = true;
    graphics.enable = true;
    # pulseaudio.enable = true;
    # hardware.nvidia.modesetting.enable = true;

    # Enable Xbox support
    # hardware.xone.enable = true;

    # Crypto wallet support
    ledger.enable = true;
  };

  # Add docker daemon
  virtualisation = {
    docker = {
      enable = true;
      logDriver = "json-file";
    };
    libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = false;
        swtpm.enable = true;
      };
    };
  };

  programs.virt-manager.enable = true;

  # libvirtd installs its own firewall rules when it starts, which can
  # shadow Docker's. Order Docker after libvirtd, and tie Docker's
  # lifecycle to libvirtd (`partOf`) so Docker is restarted — and thus
  # re-primes its firewall rules — whenever libvirtd is (re)started.
  systemd.services.docker = {
    after = [ "libvirtd.service" ];
    partOf = [ "libvirtd.service" ];
  };

  # The staging copy is kept between runs, reducing the amount of work that
  # rsync and restic need to do. Note that the staging copy lives on its own
  # dataset with snapshots disabled; see modules/nixos/disk-config.nix.
  systemd.services.voom-backup = lib.mkIf (backup.enable && backup.voomGuests) {
    description = "Back up running Voom guests into the restic repository";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      CacheDirectory = "voom-staging";
    };
    path = [
      pkgs.voom
      pkgs.jq
      pkgs.rsync
      pkgs.openssh
    ]
    ++ builtins.filter (
      p: (p.name or "") == "restic-${hostInfo.nixosHostname}"
    ) config.environment.systemPackages;
    script = ''
      # Voom uses HOME for state and XDG_RUNTIME_DIR for running-guest pidfiles.
      export HOME=${lib.escapeShellArg "/home/${user}"}
      export XDG_RUNTIME_DIR="/run/user/$UID"
      export VOOM_BACKUP_USER=${lib.escapeShellArg user}
      export VOOM_BACKUP_IDENTITY=${lib.escapeShellArg backup.voomReadIdentityFile}
      export VOOM_BACKUP_RESTIC=${lib.escapeShellArg "restic-${hostInfo.nixosHostname}"}
      exec ${pkgs.bash}/bin/bash ${../../scripts/voom-backup-linux}
    '';
  };

  systemd.timers.voom-backup = lib.mkIf (backup.enable && backup.voomGuests) {
    description = "Daily Voom guest backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
  # Swap is zram-only, so read-ahead on swap-in only decompresses pages that
  # may never be used.
  boot.kernel.sysctl."vm.page-cluster" = 0;

  users.users = {
    ${user} = {
      isNormalUser = true;
      extraGroups = [
        "wheel" # Enable ‘sudo’ for the user.
        "docker"
        "libvirtd"
        "kvm"
      ];
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = keys;
      linger = true;
    };

    root = {
      openssh.authorizedKeys.keys = keys;
    };
  };

  # Don't require password for users in `wheel` group for these commands
  security.sudo = {
    enable = true;
    extraRules = [
      {
        commands = [
          {
            command = "${pkgs.systemd}/bin/reboot";
            options = [ "NOPASSWD" ];
          }
        ];
        groups = [ "wheel" ];
      }
    ];
  };

  fonts.packages = with pkgs; [
    dejavu_fonts
    emacs-all-the-icons-fonts
    feather-font # from overlay
    jetbrains-mono
    font-awesome
    noto-fonts
    noto-fonts-color-emoji
  ];

  environment.systemPackages = with pkgs; [
    gitFull
    ghostty.terminfo
    inetutils
  ];

  system.stateVersion = "21.05"; # Don't change this

}
