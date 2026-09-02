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
  voomExcludes = [
    ".cache"
    ".npm"
    ".smolvm"
    "node_modules"
    ".direnv"
    "result"
  ];
in
{
  imports = [
    ../../modules/nixos/disk-config.nix
    ../../modules/nixos/tailscale.nix
    ../../modules/nixos/caddy.nix
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

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
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
    displayManager.defaultSession = "none+bspwm";
    libinput.enable = true;

    xserver = {
      enable = true;

      # Uncomment these for AMD or Nvidia GPU
      # boot.initrd.kernelModules = [ "amdgpu" ];
      # videoDrivers = [ "amdgpu" ];
      # videoDrivers = [ "nvidia" ];

      # Uncomment for Nvidia GPU
      # This helps fix tearing of windows for Nvidia cards
      # screenSection = ''
      #   Option       "metamodes" "nvidia-auto-select +0+0 {ForceFullCompositionPipeline=On}"
      #   Option       "AllowIndirectGLXProtocol" "off"
      #   Option       "TripleBuffer" "on"
      # '';

      displayManager = {
        lightdm = {
          enable = true;
          greeters.slick.enable = true;
          background = ../../modules/nixos/config/login-wallpaper.png;
        };
      };

      # Tiling window manager
      windowManager.bspwm = {
        enable = true;
      };

      # Turn Caps Lock into Ctrl
      xkb = {
        layout = "us";
        options = "ctrl:nocaps";
      };

    };

    # Let's be able to SSH into this machine
    openssh = {
      enable = true;
      settings.AcceptEnv = [ "SYSTEM_APPEARANCE" ];
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

    # Picom, my window compositor with fancy effects
    #
    # Notes on writing exclude rules:
    #
    #   class_g looks up index 1 in WM_CLASS value for an application
    #   class_i looks up index 0
    #
    #   To find the value for a specific application, use `xprop` at the
    #   terminal and then click on a window of the application in question
    #
    picom = {
      enable = true;
      settings = {
        animations = true;
        animation-stiffness = 300.0;
        animation-dampening = 35.0;
        animation-clamping = false;
        animation-mass = 1;
        animation-for-workspace-switch-in = "auto";
        animation-for-workspace-switch-out = "auto";
        animation-for-open-window = "slide-down";
        animation-for-menu-window = "none";
        animation-for-transient-window = "slide-down";
        corner-radius = 12;
        rounded-corners-exclude = [
          "class_i = 'polybar'"
          "class_g = 'i3lock'"
        ];
        round-borders = 3;
        round-borders-exclude = [ ];
        round-borders-rule = [ ];
        shadow = true;
        shadow-radius = 8;
        shadow-opacity = 0.4;
        shadow-offset-x = -8;
        shadow-offset-y = -8;
        fading = false;
        inactive-opacity = 0.8;
        frame-opacity = 0.7;
        inactive-opacity-override = false;
        active-opacity = 1.0;
        focus-exclude = [
        ];

        opacity-rule = [
          "100:class_g = 'i3lock'"
          "60:class_g = 'Dunst'"
          "100:class_g = 'Alacritty' && focused"
          "90:class_g = 'Alacritty' && !focused"
        ];

        blur-kern = "3x3box";
        blur = {
          method = "kernel";
          strength = 8;
          background = false;
          background-frame = false;
          background-fixed = false;
          kern = "3x3box";
        };

        shadow-exclude = [
          "class_g = 'Dunst'"
        ];

        blur-background-exclude = [
          "class_g = 'Dunst'"
        ];

        backend = "glx";
        vsync = false;
        mark-wmwin-focused = true;
        mark-ovredir-focused = true;
        detect-rounded-corners = true;
        detect-client-opacity = false;
        detect-transient = true;
        detect-client-leader = true;
        use-damage = true;
        log-level = "info";

        wintypes = {
          normal = {
            fade = true;
            shadow = false;
          };
          tooltip = {
            fade = true;
            shadow = false;
            opacity = 0.75;
            focus = true;
            full-shadow = false;
          };
          dock = {
            shadow = false;
          };
          dnd = {
            shadow = false;
          };
          popup_menu = {
            opacity = 1.0;
          };
          dropdown_menu = {
            opacity = 1.0;
          };
        };
      };
    };

    gvfs.enable = true; # Mount, trash, and other functionalities
    tumbler.enable = true; # Thumbnail support for images

    restic.backups = lib.mkIf backup.enable {
      "${hostInfo.nixosHostname}" = {
        inherit user;
        initialize = true;
        repository = "sftp:${backup.targetUser}@${backup.target}:${backup.repositoryPath}/${hostInfo.nixosHostname}";
        passwordFile = backup.passwordFile;
        paths = [ "/home/${user}" ];

        extraOptions = [
          "sftp.command='ssh ${backup.targetUser}@${backup.target} -i ${backup.identityFile} -o IdentitiesOnly=yes -s sftp'"
        ];

        exclude = [
          "/home/${user}/.local/share/voom"
          "/home/${user}/vms"
          "/home/${user}/.cache"
          "/home/${user}/.npm"
          "/home/${user}/.emacs.d.bak"
          "**/node_modules"
          "**/.direnv"
          "**/result"
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
      set -euo pipefail

      stage="$CACHE_DIRECTORY"

      # systemd does not set these env vars for a User= service. (Important,
      # because voom resolves its state directory from HOME and decides that a
      # guest is running by finding its pidfile under XDG_RUNTIME_DIR.)
      export HOME=${lib.escapeShellArg "/home/${user}"}
      export XDG_RUNTIME_DIR="/run/user/$UID"
      key=${lib.escapeShellArg backup.voomReadIdentityFile}

      known="$(voom list --output json | jq -r '.[].name')"
      if [ -n "$known" ]; then
        for d in "$stage"/*; do
          [ -d "$d" ] || continue
          if ! printf '%s\n' "$known" | grep -qxF "$(basename "$d")"; then
            echo "removing staging for unknown guest $(basename "$d")"
            rm -rf "$d"
          fi
        done
      fi

      # Skip stopped guests.
      guests="$(voom list --output json \
        | jq -r '.[] | select(.status == "running") | "\(.name) \(.sshPort)"')"

      if [ -z "$guests" ]; then
        echo "no running guests to back up" >&2
        exit 0
      fi

      printf '%s\n' "$guests" | while read -r name port; do
        echo "==> $name"
        dest="$stage/$name"

        home_ok=1
        for path in /home /var/lib/docker/volumes; do
          mkdir -p "$dest$path"
          # No --rsync-path: the guest forces `sudo rrsync -ro /`, which
          # supplies both the privilege and the read-only restriction.
          set +e
          rsync -aHAXS --delete ${
            lib.concatMapStringsSep " " (e: "--exclude=${lib.escapeShellArg e}") voomExcludes
          } \
            -e "ssh -p $port -i $key -o IdentitiesOnly=yes -o BatchMode=yes \
                -o LogLevel=ERROR -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null" \
            ${user}@127.0.0.1:"$path/" "$dest$path/"
          rc=$?
          set -e
          # 24 is rsync's own warning for source files that vanished mid-copy,
          # which is routine on a running guest.
          case $rc in
            0|24) ;;
            *) echo "!! $name: $path not captured (rsync exit $rc)" >&2
               if [ "$path" = /home ]; then home_ok=0; fi ;;
          esac
        done

        # Leave a partial copy in place: --delete reconciles it next run,
        # and discarding it would force a full re-transfer.
        if [ "$home_ok" = 0 ]; then
          echo "!! $name: skipped" >&2
          continue
        fi

        # --host gives each guest its own identity in the repository.
        #
        # restic exits 3 when it saved a snapshot but could not read every
        # source file; this is treated as a warning instead of a failed backup.
        set +e
        restic-${hostInfo.nixosHostname} backup --host "$name" --tag voom "$dest"
        rc=$?
        set -e
        case $rc in
          0) ;;
          3) echo "!! $name: snapshot saved, some files unreadable" >&2 ;;
          *) echo "!! $name: backup failed (restic exit $rc)" >&2 ;;
        esac
      done
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
