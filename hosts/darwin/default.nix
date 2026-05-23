{ config, osConfig, pkgs, userInfo, systemType, ... }:

let user = userInfo.user;
    keys = userInfo.sshKeys; in

{

  imports = [
    ../../modules/darwin/home-manager.nix
    ../../modules/shared
    ../../modules/shared/caches
  ];

  # Setup user, packages, programs
  nix = {
    package = pkgs.nixVersions.latest;
    settings.trusted-users = [ "@admin" "${user}" ];

    # Run a small aarch64-linux NixOS VM under vfkit so this Mac can build
    # Linux derivations without a remote builder. The first activation
    # substitutes the prebuilt VM image from the Nix binary cache. Small
    # `config` overrides (like the disk size below) don't trigger any
    # aarch64-linux builds, so fresh activation works in one shot; heavier
    # customizations may need the builder enabled first, then the override
    # layered on a subsequent switch.
    #
    # Desktop only: the daemon runs persistently (launchd KeepAlive,
    # no on-demand activation) and the vfkit process holds its allocated
    # guest RAM (default 3 GiB) continuously.
    linux-builder = {
      enable = systemType == "desktop";
      # Override the default 20 GiB virtual disk. The base NixOS system,
      # closure substituted from cache, `/build/root` rsync staging copy,
      # and the inner `nixos-disk-image` vda1 file all share this volume
      # during a bake, which easily exceeds 20 GiB for non-trivial
      # closures. Sparse on the Mac side, so unused space is free.
      config.virtualisation.darwin-builder.diskSize = 100 * 1024;
    };

    gc = {
      automatic = true;
      interval = { Weekday = 0; Hour = 2; Minute = 0; };
      options = "--delete-older-than 30d";
    };

    # Turn this on to make command line easier
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Turn off NIX_PATH warnings now that we're using flakes
  system.checks.verifyNixPath = false;

  # Load configuration that is shared across systems
  environment.systemPackages = with pkgs; [

  ] ++ (import ../../modules/shared/packages.nix { inherit pkgs; });

  # Set fish as the default shell
  programs.fish.enable = true;

  users.users.${user}.openssh.authorizedKeys.keys = keys;

  system = {
    stateVersion = 4;

    primaryUser = user;

    defaults = {
      NSGlobalDomain = {
        AppleShowAllExtensions = true;
        ApplePressAndHoldEnabled = false;

        # 120, 90, 60, 30, 12, 6, 2
        KeyRepeat = 2;

        # 120, 94, 68, 35, 25, 15
        InitialKeyRepeat = 15;

        "com.apple.mouse.tapBehavior" = 1;
        "com.apple.swipescrolldirection" = false;
      };

      dock = {
        autohide = true;
        show-recents = true;
        launchanim = true;
        orientation = "bottom";
        tilesize = 64;
      };

      finder = {
        _FXShowPosixPathInTitle = false;
      };

      trackpad = {
        Clicking = true;
      };
    };

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToControl = true;
    };
  };
}
