{
  nixpkgs,
  pkgs,
  userInfo,
  ...
}:

let
  user = userInfo.user;
  # Shared overlays would change the paths provided by cache.nixos-cuda.org.
  cudaPkgs = import nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
    };
  };
in
{
  imports = [
    ../../modules/shared
    ../../modules/shared/caches
  ];

  wsl = {
    enable = true;
    defaultUser = user;
    useWindowsDriver = true;
    interop.includePath = false;
    wslConf = {
      automount.enabled = false;
      interop = {
        enabled = false;
        appendWindowsPath = false;
      };
    };
  };

  nix = {
    package = pkgs.nixVersions.latest;
    settings = {
      allowed-users = [ user ];
      trusted-users = [
        "@wheel"
        user
      ];
      substituters = [ "https://cache.nixos-cuda.org" ];
      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
    };
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  programs = {
    fish.enable = true;
    gnupg.agent.enable = true;
    ssh.startAgent = true;
  };

  time.timeZone = "America/New_York";

  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      AcceptEnv = [ "SYSTEM_APPEARANCE" ];
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      GatewayPorts = "no";
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      PermitTunnel = "no";
      X11Forwarding = false;
    };
  };

  users.users.${user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = userInfo.sshKeys;
    linger = true;
  };

  environment.systemPackages = [
    cudaPkgs.blender
    (pkgs.writeShellScriptBin "nvidia-smi" ''
      exec /usr/lib/wsl/lib/nvidia-smi "$@"
    '')
  ];

  system.stateVersion = "26.05";
}
