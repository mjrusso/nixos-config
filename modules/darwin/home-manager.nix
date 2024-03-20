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
