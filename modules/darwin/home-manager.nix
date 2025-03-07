{ config, osConfig, pkgs, lib, home-manager, mac-app-util, systemType, ... }:

let
  user = "mjrusso";
  homeDir = "/Users/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };

  # List of folders that will be automatically mirrored to another location on
  # the file system. (Here, rsync is used for one-way sync.) Source folders are
  # expected to contain an `.rsyncignore` file.
  localSyncFolders = [{
    name = "git";
    src = "${homeDir}/git";
    dest = "${homeDir}/Dropbox/backup/syncthing/git";
  }];

in {

  users.users.${user} = {
    name = "${user}";
    home = homeDir;
    isHidden = false;
    shell = pkgs.fish;
  };

  # Enable home-manager
  home-manager = {
    useGlobalPkgs = true;
    users.${user} = { pkgs, config, osConfig, lib, ... }: {
      imports = [
        # Use the `mac-app-util` module to ensure that app launchers (e.g.
        # Emacs) are properly symlinked (so they can be found via Spotlight,
        # are pinnable to the Dock, etc.).
        #
        # See documentation: https://github.com/hraban/mac-app-util
        #
        # Also see: https://github.com/nix-community/home-manager/issues/1341
        mac-app-util.homeManagerModules.default
      ];

      # Create one launchd agent per `localSyncFolders` entry. Each agent
      # copies files from the source directory to the destination directory,
      # whenever files in the source directory change.
      launchd.agents = builtins.listToAttrs (map (folder: {
        name = "local-sync-${folder.name}";
        value = {
          enable = true;
          config = {
            ProgramArguments = [
              "${pkgs.rsync}/bin/rsync"
              "-a"
              "--delete"
              "--filter=dir-merge /.rsyncignore"
              "${lib.escapeShellArg "${folder.src}/"}"
              "${lib.escapeShellArg "${folder.dest}/"}"
            ];
            RunAtLoad = true;
            # Automatically run if the source directory changes.
            WatchPaths = [ folder.src ];
            # Run every 300 seconds regardless of whether anything changed.
            StartInterval = 300;
            # Wait a minimum 5 seconds between job invocations.
            ThrottleInterval = 5;
            StandardOutPath =
              "${homeDir}/Library/Logs/local-sync-${folder.name}.log";
            StandardErrorPath =
              "${homeDir}/Library/Logs/local-sync-${folder.name}.log";
          };
        };
      }) localSyncFolders);

      home = {
        enableNixpkgsReleaseCheck = false;
        packages = pkgs.callPackage ./packages.nix { };
        sessionPath = [
          "$HOME/.local/bin"

          # Ensure that Homebrew is in the PATH. (Technically we should only be
          # adding this specific directory if we're on an Apple Silicon-based
          # Mac.) Note that this puts `/opt/homebrew` at the end of PATH; this
          # means that in the case of binaries that ship with MacOS that are
          # also installed via Homebrew, the binaries that ship with MacOS will
          # take precedence (which may not be expected).
          "/opt/homebrew/bin"
        ];
        sessionVariables = {
          EDITOR = "ec";
          LIMA_WORKDIR = "/home/${user}.linux";
        };
        file = lib.mkMerge [ sharedFiles additionalFiles ];
        stateVersion = "23.11";

        # Ensure that destination folders exist before running the launchd agent
        # for local syncing.
        activation.createLocalSyncDirs =
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            ${builtins.concatStringsSep "\n" (map (folder: ''
              mkdir -p "${folder.dest}"
            '') localSyncFolders)}
          '';
      };
      fonts.fontconfig.enable = true;
      programs = { } // import ../shared/home-manager.nix {
        inherit config osConfig pkgs lib;
      };
    };
  };

}
