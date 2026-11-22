{ config, lib, pkgs, ... }:

let
  user = "tailnet-caddy-guest";
  guest = pkgs.callPackage ../../packages/tailnet-caddy-guest.nix {
    tailscale = config.services.tailscale.package;
    runtimeDir = "/run/${user}";
    listListeners = "jq .listeners /run/voom/ports.json";
    ephemeralPorts = "cat /proc/sys/net/ipv4/ip_local_port_range";
  };
in
{
  options.services.tailnetCaddyGuest.enable = lib.mkEnableOption ''
    publishing this guest's web apps through the tailnet host running
    services.tailnetCaddy'';

  config = lib.mkIf config.services.tailnetCaddyGuest.enable {
    services.tailscale.enable = true;

    environment.systemPackages = [ guest.sync ];

    # The syncer must run as the owner of Caddy's admin socket.
    systemd.services.tailnet-caddy-guest = {
      description = "Proxy tailnet requests to this guest's HTTP listeners";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      serviceConfig = {
        DynamicUser = true;
        User = user;
        RuntimeDirectory = user;
        ExecStart = guest.start;
        Restart = "always";
        RestartSec = 5;
      };
    };

    systemd.services.tailnet-caddy-guest-sync = {
      description = "Publish this guest's HTTP listeners through tailnet-caddy-guest";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailnet-caddy-guest.service" ];
      serviceConfig = {
        DynamicUser = true;
        User = user;
        ExecStart = lib.getExe guest.sync;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
