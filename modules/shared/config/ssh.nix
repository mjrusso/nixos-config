{ config, pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  enable = true;
  enableDefaultConfig = false;

  includes = [
    # Scratch file for ad-hoc Host entries, outside this (read-only)
    # home-manager-managed config. Optional; SSH ignores if absent.
    "${config.home.homeDirectory}/.ssh/config.local"
  ] ++ lib.optionals isDarwin [
    # Colima's generated SSH config, written to ~/.colima/ssh_config whenever a
    # Colima VM is running. (MacOS only.)
    "${config.home.homeDirectory}/.colima/ssh_config"
  ];

  matchBlocks."*" = {
    addKeysToAgent = "yes";
    identityFile = "~/.ssh/id_ed25519";
    sendEnv = [ "SYSTEM_APPEARANCE" ];

    # `UseKeychain yes` tells ssh to read the key's passphrase from the MacOS
    # login Keychain. This is an Apple OpenSSH extension, and exclusive to
    # Darwin hosts only.
    #
    # Requires one-time setup per MacOS host: store the passphrase with
    # `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.
    extraOptions = lib.optionalAttrs isDarwin {
      UseKeychain = "yes";
    };
  };
}
