{ config, osConfig, pkgs, lib, home-manager, mac-app-util, ... }:

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
        packages = pkgs.callPackage ./packages.nix {};
        sessionPath = [];
        sessionVariables = {
          EDITOR = "${pkgs.my-emacs-with-packages}/bin/emacsclient";
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
