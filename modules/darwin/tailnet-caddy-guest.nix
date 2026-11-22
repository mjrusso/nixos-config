{ config, lib, pkgs, ... }:

let
  guest = pkgs.callPackage ../../packages/tailnet-caddy-guest.nix {
    tailscale = config.services.tailscale.package;
    runtimeDir = "/var/run/tailnet-caddy-guest";
    listListeners = toString (pkgs.writeShellScript "list-tcp-listeners" ''
      /usr/sbin/lsof -nP +c 0 -iTCP -sTCP:LISTEN -F pcn \
        | ${pkgs.gawk}/bin/awk '
            /^p/ { pid = substr($0, 2) }
            /^c/ { process = substr($0, 2) }
            /^n/ {
              name = substr($0, 2)
              match(name, /:[0-9]+$/)
              address = substr(name, 1, RSTART - 1)
              gsub(/^\[|\]$/, "", address)
              print pid "\t" process "\t" address "\t" substr(name, RSTART + 1)
            }' \
        | ${lib.getExe pkgs.jq} -Rn '
            [inputs | split("\t")
              | {pid: (.[0] | tonumber), process: .[1], addr: .[2], port: (.[3] | tonumber)}]'
    '');
    ephemeralPorts = toString (pkgs.writeShellScript "ephemeral-ports" ''
      echo "$(/usr/sbin/sysctl -n net.inet.ip.portrange.first) $(/usr/sbin/sysctl -n net.inet.ip.portrange.last)"
    '');
  };
  log = "/var/log/tailnet-caddy-guest.log";
in
{
  options.services.tailnetCaddyGuest.enable = lib.mkEnableOption ''
    publishing this guest's web apps through the tailnet host running
    services.tailnetCaddy'';

  config = lib.mkIf config.services.tailnetCaddyGuest.enable {
    services.tailscale.enable = true;

    environment.systemPackages = [ guest.sync ];

    # The syncer needs root for lsof to see other users' listeners.
    launchd.daemons.tailnet-caddy-guest = {
      command = "${guest.start}";
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = log;
        StandardErrorPath = log;
      };
    };

    launchd.daemons.tailnet-caddy-guest-sync = {
      command = lib.getExe guest.sync;
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = log;
        StandardErrorPath = log;
      };
    };
  };
}
