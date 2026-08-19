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

  settings."*" = {
    AddKeysToAgent = "yes";
    IdentityFile = "~/.ssh/id_ed25519";
    SendEnv = [ "SYSTEM_APPEARANCE" ];
  } // lib.optionalAttrs isDarwin {
    # `UseKeychain yes` tells ssh to read the key's passphrase from the MacOS
    # login Keychain. This is an Apple OpenSSH extension, and exclusive to
    # Darwin hosts only.
    #
    # Requires one-time setup per MacOS host: store the passphrase with
    # `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.
    UseKeychain = "yes";
  };
}
