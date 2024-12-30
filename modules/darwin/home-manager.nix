{ config, osConfig, pkgs, lib, home-manager, mac-app-util, ... }:

let
  user = "mjrusso";
  sharedFiles = import ../shared/files.nix { inherit config pkgs; };
  additionalFiles = import ./files.nix { inherit user config pkgs; };
in {

  users.users.${user} = {
    name = "${user}";
    home = "/Users/${user}";
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
          EDITOR = "${pkgs.my-emacs-with-packages}/bin/emacsclient";
          LIMA_WORKDIR = "/home/${user}.linux";
        };
        file = lib.mkMerge [ sharedFiles additionalFiles ];
        stateVersion = "23.11";
      };
      fonts.fontconfig.enable = true;
      programs = { } // import ../shared/home-manager.nix {
        inherit config osConfig pkgs lib;
      };
    };
  };

}
