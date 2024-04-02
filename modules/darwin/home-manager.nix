{ config, osConfig, pkgs, lib, home-manager, ... }:

let
  user = "mjrusso";
  sharedFiles = import ../shared/files.nix { inherit config pkgs; };
  additionalFiles = import ./files.nix { inherit user config pkgs; };
in
{

  users.users.${user} = {
    name = "${user}";
    home = "/Users/${user}";
    isHidden = false;
    shell = pkgs.fish;
  };

  # Enable home-manager
  home-manager = {
    useGlobalPkgs = true;
    users.${user} = { pkgs, config, osConfig, lib, ... }:{
      home = {
        enableNixpkgsReleaseCheck = false;
        packages = pkgs.callPackage ./packages.nix {};
        sessionPath = [
          # Ensure that Homebrew is in the PATH on Macs running Apple Silicon.
          # (Technically we should only add this if we're on an Apple Silicon-based Mac.)
          "/opt/homebrew/bin"
        ];
        sessionVariables = {
          EDITOR = "${pkgs.my-emacs-with-packages}/bin/emacsclient";
        };
        activation = {
          # Ensure that app launchers (e.g. Emacs) are properly symlinked (so
          # they can be found via Spotlight, are pinnable to the Dock, etc.).
          #
          # See more discussion here:
          # https://github.com/nix-community/home-manager/issues/1341
          #
          # In particular, this approach is adapted from:
          # https://github.com/nix-community/home-manager/issues/1341#issuecomment-761021848
          #
          # Note that the `readlink` is necessary because because Mac aliases
          # don't work on symlinks, as explained here:
          # https://github.com/NixOS/nix/issues/956#issuecomment-1367457122
          aliasApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            app_folder=$(echo /Applications);
            for app in $(find "$genProfilePath/home-path/Applications" -type l); do
              $DRY_RUN_CMD rm -f $app_folder/$(basename $app)
              $DRY_RUN_CMD /usr/bin/osascript -e "tell app \"Finder\"" -e "make new alias file to POSIX file \"$(readlink $app)\" at POSIX file \"$app_folder\"" -e "set name of result to \"$(basename $app)\"" -e "end tell"
            done
          '';

        };
        file = lib.mkMerge [
          sharedFiles
          additionalFiles
        ];
        stateVersion = "23.11";
      };
      programs = {} // import ../shared/home-manager.nix { inherit config osConfig pkgs lib; };
    };
  };

}
