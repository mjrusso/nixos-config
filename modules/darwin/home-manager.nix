{ config, osConfig, pkgs, lib, home-manager, mac-app-util, userInfo, ... }:

let
  user = userInfo.user;
  homeDir = "/Users/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };

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

      home = {
        enableNixpkgsReleaseCheck = false;
        packages = pkgs.callPackage ./packages.nix { };
        sessionPath = [
          "$HOME/.local/bin"
        ];
        sessionVariables = {
          PATH = "$PATH:$HOME/.npm/bin";
          EDITOR = "ec";
          LIMA_WORKDIR = "/home/${user}.linux";
        };
        file = lib.mkMerge [ sharedFiles additionalFiles ];
        stateVersion = "23.11";

        # Open text files in CotEditor instead of Xcode (or whatever app
        # happens to be registered as the default). Note that CotEditor is
        # installed manually (using `brew install --cask coteditor`); skip if
        # it isn't installed on this system.
        activation.defaultTextEditor = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -d /Applications/CotEditor.app ]; then
            for t in public.plain-text public.source-code public.script \
                     public.shell-script public.python-script public.json \
                     public.yaml public.xml net.daringfireball.markdown \
                     .md .nix .toml; do
              run ${pkgs.duti}/bin/duti -s com.coteditor.CotEditor "$t" all
            done
          fi
        '';
      };
      fonts.fontconfig.enable = true;
      programs = { } // import ../shared/home-manager.nix {
        inherit config osConfig pkgs lib userInfo;
      };
    };
  };

}
