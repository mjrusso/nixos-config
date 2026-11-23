{ config, pkgs, lib, ... }:

let
  cfg = config.services.tailnetCaddy;
  # Must match the tag in the README's join command and tailnet policy.
  peerTag = "tag:voom-vm";
  caddyCloudflareVersion = "v0.2.4";
  # The hash covers Caddy's Go modules as well as the plugin's, so it is valid
  # only for the Caddy version it was computed against. A nixpkgs update can
  # also change it without changing the Caddy version, which the assertion
  # below cannot detect; the build then fails with a hash mismatch instead.
  caddyCloudflareHashCaddyVersion = "2.11.7";
  caddyCloudflareHash = "sha256-tubXIDCJnO2mvdnPlZclwDhNGaeeYLSt7lnni3+pXDo=";

  routeModule = lib.types.submodule {
    options = {
      domain = lib.mkOption {
        type = lib.types.str;
        description = "Base DNS domain for this private Caddy route set.";
      };

      syncer = lib.mkOption {
        type = lib.types.enum [ "tailnet" "docker" "none" ];
        default = "tailnet";
        description = ''
          The `tailnet` syncer publishes guests tagged `${peerTag}`. The
          `docker` syncer publishes containers with a `caddy.host` label.
          Use `none` to manage the route list through the Caddy admin API.
        '';
      };
    };
  };

  routeId = routeName: "${routeName}_routes";

  mkWildcardHost = routeCfg: "*.${routeCfg.domain}";

  mkTlsPolicy = routeCfg: {
    subjects = [ (mkWildcardHost routeCfg) ];
    issuers = [{
      module = "acme";
      challenges.dns.provider = {
        name = "cloudflare";
        api_token = "{env.CLOUDFLARE_API_TOKEN}";
      };
    }];
  };

  mkHttpRoute = routeName: routeCfg: {
    match = [{ host = [ (mkWildcardHost routeCfg) ]; }];
    handle = [
      {
        handler = "subroute";
        "@id" = routeId routeName;
        routes = [ ];
      }
      {
        handler = "static_response";
        status_code = 404;
        body = ''
          no ${routeName} route
        '';
      }
    ];
    terminal = true;
  };

  mkDockerSyncPackage = routeName: routeCfg:
    let
      commandName = if routeName == "docker" then
        "docker-caddy-sync"
      else
        "docker-caddy-sync-${routeName}";
    in pkgs.writeShellApplication {
      name = commandName;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
        config.virtualisation.docker.package
      ];
      text = ''
        set -euo pipefail

        usage() {
          cat <<'EOF'
        Usage: ${commandName} [options]

        Publish Docker containers labelled `caddy.host` through this Caddy route.

        Container labels:
          caddy.host=<names>          Required. Comma-separated list of names,
                                      each published at <name>.${routeCfg.domain}.
                                      Every name must be a single DNS label: the
                                      wildcard certificate and route match one
                                      level only.
          caddy.upstream=<host:port>  Dial address override. Defaults to the
                                      container's lowest 127.0.0.1 published port.
          caddy.csp=<policy>          Content-Security-Policy to set on responses.
          caddy.csp-paths=<paths>     Comma-separated Caddy path matchers limiting
                                      where caddy.csp applies (default: everywhere).
          caddy.paths=<paths>         Comma-separated Caddy path matchers; anything
                                      outside them gets a 404 (default: serve all).
          caddy.rewrite-from=<path>   Rewrite this request path to
          caddy.rewrite-to=<uri>      this upstream URI. Both or neither.

        Any label above except caddy.host may be suffixed with .<name> to apply
        to one published name only, which is how one container serves different
        things on each of its names. The suffixed value wins where both are set.

        Containers without a caddy.host label are never published.

        Options:
          --admin URL             Caddy admin API URL (default: http://localhost:2019)
          --watch                 Keep running, re-syncing on container start/die
          --dry-run               Print generated routes instead of patching Caddy
          --help                  Show this help
        EOF
        }

        admin_url="http://localhost:2019"
        route_id=${lib.escapeShellArg (routeId routeName)}
        domain=${lib.escapeShellArg routeCfg.domain}
        watch=0
        dry_run=0

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --admin)
              admin_url="''${2:?missing value for --admin}"
              shift 2
              ;;
            --watch)
              watch=1
              shift
              ;;
            --dry-run)
              dry_run=1
              shift
              ;;
            --help|-h)
              usage
              exit 0
              ;;
            *)
              echo "unknown argument: $1" >&2
              usage >&2
              exit 2
              ;;
          esac
        done

        log() {
          echo "${commandName}: $*" >&2
        }

        # Every name claimed by a container labelled caddy.host, as a JSON array,
        # one record per name. `valid` flags the names usable as a single DNS
        # label; `dial` prefers an explicit caddy.upstream over the lowest
        # 127.0.0.1 published port.
        gather() {
          local ids

          ids="$(docker ps --filter label=caddy.host --format '{{.ID}}')"

          if [[ -z "$ids" ]]; then
            printf '[]\n'
            return 0
          fi

          # shellcheck disable=SC2086
          docker inspect $ids | jq --arg domain "$domain" '
            def csv: split(",") | map(gsub("[[:space:]]"; "")) | map(select(. != ""));

            def pick($labels; $sub; key):
              ($labels[key + "." + $sub]) // ($labels[key]) // "";

            [
              .[]
              | (.Config.Labels // {}) as $labels
              | ((($labels["caddy.host"]) // "") | ascii_downcase) as $claimed
              | select($claimed != "")
              | (
                  [
                    (.NetworkSettings.Ports // {})
                    | to_entries[]
                    | (.value // [])[]
                    | select(.HostIp == "127.0.0.1")
                    | .HostPort
                  ]
                  | sort_by(tonumber)
                  | first
                ) as $published
              # Every per-name label must be read below this fan-out; a lookup
              # hoisted above it silently ignores its .<name> override and
              # publishes against the container-wide value instead. Note that
              # `unique` is crucial: without it, caddy.host=a,a reports
              # a collision against itself.
              | ($claimed | csv | unique)[] as $sub
              | (pick($labels; $sub; "caddy.upstream")) as $upstream
              | (
                  # `//` is no use here: pick yields "" when the label is unset,
                  # and jq counts the empty string as truthy.
                  if $upstream != "" then
                    $upstream
                  elif $published == null then
                    null
                  else
                    "127.0.0.1:" + $published
                  end
                ) as $dial
              | select($dial != null)
              | (pick($labels; $sub; "caddy.rewrite-from")) as $rw_from
              | (pick($labels; $sub; "caddy.rewrite-to")) as $rw_to
              | {
                  sub: $sub,
                  valid: (
                    ($sub | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))
                    and (($sub | length) <= 63)
                  ),
                  host: ($sub + "." + $domain),
                  dial: $dial,
                  csp: pick($labels; $sub; "caddy.csp"),
                  cspPaths: (pick($labels; $sub; "caddy.csp-paths") | csv),
                  paths: (pick($labels; $sub; "caddy.paths") | csv),
                  rewriteFrom: $rw_from,
                  rewriteTo: $rw_to,
                  # Reported at sync time: a half-set rewrite would otherwise
                  # publish the name with its friendly path 404ing and nothing
                  # to say why.
                  rewritePartial: (($rw_from == "") != ($rw_to == ""))
                }
            ]'
        }

        sync_once() {
          local all
          local claimed
          local containers
          local routes
          local response
          local status
          local count

          all="$(gather)"

          while IFS= read -r bad; do
            [[ -n "$bad" ]] || continue
            log "skipping container: caddy.host is not a DNS label: $bad"
          done < <(jq -r '.[] | select(.valid | not) | .sub' <<<"$all")

          while IFS= read -r partial; do
            [[ -n "$partial" ]] || continue
            log "ignoring rewrite for $partial: needs both caddy.rewrite-from and caddy.rewrite-to"
          done < <(jq -r '.[] | select(.rewritePartial) | .sub' <<<"$all")

          claimed="$(jq '[ .[] | select(.valid) ]' <<<"$all")"

          # caddy.host names are host-wide, and multiple containers can
          # (attempt to) claim the same name. Caddy serves the first matching
          # route and reverse_proxy never calls the next handler, so a duplicate
          # would be shadowed with no indication of why. Report the collision
          # rather than failing the whole sync.
          while IFS= read -r collision; do
            log "$collision"
          done < <(jq -r '
            group_by(.sub)
            | map(select(length > 1))[]
            | "caddy.host=" + .[0].sub + " claimed by " + (length | tostring)
              + " containers (" + ([ .[].dial ] | sort | join(", ")) + "); publishing "
              + (sort_by(.dial) | first | .dial)
          ' <<<"$claimed")

          # Resolve collisions by ordering on the dial address, so the same
          # container keeps the name on every sync; `docker ps` ordering would
          # hand it to whichever container was created most recently. The log
          # line above names the winning upstream, so which one wins is visible.
          containers="$(jq 'group_by(.sub) | map(sort_by(.dial) | first)' <<<"$claimed")"
          # The caddy.paths gate must come before the rewrite, so that it
          # matches the URI the client sent.
          routes="$(jq '
            [
              .[]
              | {
                  handler: "reverse_proxy",
                  stream_close_delay: "1h",
                  upstreams: [ { dial: .dial } ]
                } as $proxy
              | (
                  (
                    if (.paths | length) == 0 then
                      [ ]
                    else
                      [ {
                        match: [ { not: [ { path: .paths } ] } ],
                        handle: [ {
                          handler: "static_response",
                          status_code: 404,
                          body: "not published on this name\n"
                        } ],
                        terminal: true
                      } ]
                    end
                  )
                  + (
                    if .csp == "" then
                      [ ]
                    else
                      # A route carrying only a headers handler is non-terminal,
                      # so it sets the policy and falls through to the proxy
                      # route below. That is what allows caddy.csp-paths to scope
                      # the policy to some paths and not others.
                      [ (
                        {
                          handle: [ {
                            handler: "headers",
                            response: {
                              # deferred applies the header when the response is
                              # written, so it wins over one the upstream sets.
                              set: { "Content-Security-Policy": [ .csp ] },
                              deferred: true
                            }
                          } ]
                        }
                        + (
                          if (.cspPaths | length) == 0 then
                            { }
                          else
                            { match: [ { path: .cspPaths } ] }
                          end
                        )
                      ) ]
                    end
                  )
                  + (
                    if .rewritePartial or .rewriteFrom == "" then
                      [ ]
                    else
                      [ {
                        match: [ { path: [ .rewriteFrom ] } ],
                        handle: [ { handler: "rewrite", uri: .rewriteTo } ]
                      } ]
                    end
                  )
                  + [ { handle: [ $proxy ] } ]
                ) as $stages
              | {
                  match: [ { host: [ .host ] } ],
                  handle: (
                    if ($stages | length) == 1 then
                      [ $proxy ]
                    else
                      [ { handler: "subroute", routes: $stages } ]
                    end
                  )
                }
            ]' <<<"$containers")"

          if [[ "$dry_run" -eq 1 ]]; then
            jq . <<<"$routes"
            return 0
          fi

          status="$(curl -sS -o /dev/null -w '%{http_code}' "$admin_url/id/$route_id/routes" || true)"
          case "$status" in
            200)
              ;;
            404)
              log "Caddy route target @id=$route_id does not exist"
              return 1
              ;;
            *)
              log "could not inspect Caddy route target @id=$route_id: HTTP $status"
              return 1
              ;;
          esac

          if ! response="$(curl -sS --fail-with-body -X PATCH \
            -H 'Content-Type: application/json' \
            --data-binary "$routes" \
            "$admin_url/id/$route_id/routes")"; then
            log "could not patch Caddy route target @id=$route_id: $response"
            return 1
          fi

          count="$(jq 'length' <<<"$routes")"
          log "synced $count Caddy route(s) from Docker labels"
        }

        if [[ "$watch" -eq 0 ]]; then
          sync_once
          exit 0
        fi

        sync_once || log "initial sync failed (continuing)"
        log "watching Docker container events"

        while IFS= read -r _; do
          # Coalesce bursts: `docker compose up` emits one event per container,
          # and each sync PATCHes the whole route list anyway.
          while IFS= read -r -t 1 _; do :; done
          sync_once || log "sync failed (continuing)"
        done < <(
          docker events \
            --filter type=container \
            --filter event=start \
            --filter event=die
        )

        log "Docker event stream ended"
        exit 1
      '';
    };

  mkPeerSyncPackage = routeName: routeCfg:
    let
      commandName = "tailnet-caddy-peer-sync-${routeName}";
    in pkgs.writeShellApplication {
      name = commandName;
      runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq config.services.tailscale.package ];
      text = ''
        admin_url="http://localhost:2019/id/${routeId routeName}/routes"
        dry_run=0

        case "''${1:-}" in
          "") ;;
          --dry-run) dry_run=1 ;;
          *) echo "usage: ${commandName} [--dry-run]" >&2; exit 2 ;;
        esac

        log() {
          echo "${commandName}: $*" >&2
        }

        # Keep offline peers so Caddy returns 502 for an unreachable guest.
        # The policy lets tagged peers reach this host on port 443, so the first
        # route refuses every source except this host and untagged peers. That
        # includes a guest that joined since the last poll.
        peer_routes() {
          tailscale status --json | jq -cS \
            --arg tag ${lib.escapeShellArg peerTag} \
            --arg domain ${lib.escapeShellArg (lib.escapeRegex routeCfg.domain)} \
            --arg port ${toString (import ../../packages/tailnet-caddy-guest-port.nix)} '
              def tagged: (.Tags // []) | index($tag) != null;
              [ (.Peer // {})[] ] as $peers
              | ([ (.Self.TailscaleIPs // [])[], ($peers[] | select(tagged | not) | .TailscaleIPs[]) ]
                  | sort) as $allowed
              | [ {
                  match: [ { not: [ { remote_ip: { ranges: $allowed } } ] } ],
                  handle: [ {
                    handler: "static_response",
                    status_code: 403,
                    body: "source not allowed\n"
                  } ]
                } ]
              + ([
                  $peers[]
                  | select(tagged)
                  | (.DNSName | split(".")[0]) as $name
                  | (.TailscaleIPs | map(select(test("^[0-9.]+$"))) | first) as $ip
                  | select($ip != null)
                  | {
                      match: [ {
                        vars_regexp: {
                          "{http.request.host}": {
                            pattern: ("^" + $name + "-[0-9]+\\." + $domain + "$")
                          }
                        }
                      } ],
                      handle: [ {
                        handler: "reverse_proxy",
                        stream_close_delay: "1h",
                        upstreams: [ { dial: ($ip + ":" + $port) } ]
                      } ]
                    }
                ]
                | sort_by(.match[0].vars_regexp[].pattern))'
        }

        if [[ "$dry_run" -eq 1 ]]; then
          peer_routes | jq .
          exit 0
        fi

        # Caddy clears its route list on restart.
        while :; do
          if ! want="$(peer_routes)"; then
            log "could not read tailscale status"
          elif ! response="$(curl -sS --fail-with-body "$admin_url")"; then
            log "could not read Caddy routes at $admin_url: $response"
          elif ! have="$(jq -cS . <<<"$response")"; then
            log "could not parse Caddy routes at $admin_url"
          elif [[ "$want" != "$have" ]]; then
            if response="$(curl -sS --fail-with-body -X PATCH \
              -H 'Content-Type: application/json' \
              --data-binary "$want" "$admin_url")"; then
              log "synced $(jq length <<<"$want") tailnet peer route(s)"
            else
              log "could not patch Caddy routes at $admin_url: $response"
            fi
          fi
          sleep 10
        done
      '';
    };

  mkPeerSyncUnit = routeName: routeCfg:
    let
      pkg = mkPeerSyncPackage routeName routeCfg;
    in lib.nameValuePair pkg.name {
      description = "Sync Caddy '${routeName}' routes to tailnet peers tagged ${peerTag}";
      wantedBy = [ "multi-user.target" ];
      after = [ "caddy.service" "tailscaled.service" ];
      serviceConfig = {
        User = cfg.syncUser;
        ExecStart = "${pkg}/bin/${pkg.name}";
        Restart = "always";
        RestartSec = 5;
      };
    };

  # Block until Caddy's admin API is serving, so a sync triggered at Caddy
  # startup does not race the admin endpoint coming up.
  waitForCaddyAdmin = pkgs.writeShellScript "wait-caddy-admin" ''
    n=0
    until ${pkgs.curl}/bin/curl -sf -o /dev/null http://localhost:2019/config/; do
      n=$((n + 1))
      if [ "$n" -ge 30 ]; then
        echo "Caddy admin API not ready after 30s" >&2
        exit 1
      fi
      sleep 1
    done
  '';

  mkDockerSyncUnits = routeName: routeCfg:
    let
      pkg = mkDockerSyncPackage routeName routeCfg;
      exe = "${pkg}/bin/${pkg.name}";
    in [
      (lib.nameValuePair pkg.name {
        description = "Re-seed Caddy '${routeName}' routes from Docker labels";
        after = [ "caddy.service" "docker.service" ];
        requires = [ "caddy.service" "docker.service" ];
        wantedBy = [ "caddy.service" ]; # start with Caddy (e.g. at boot)
        partOf = [ "caddy.service" ]; # and re-run when Caddy restarts
        serviceConfig = {
          Type = "oneshot";
          # partOf only propagates restarts to units that are active, and a
          # oneshot without this goes inactive as soon as it succeeds.
          RemainAfterExit = true;
          User = cfg.syncUser;
          ExecStartPre = "${waitForCaddyAdmin}";
          ExecStart = exe;
        };
      })
      (lib.nameValuePair "${pkg.name}-watch" {
        description =
          "Re-sync Caddy '${routeName}' routes on Docker container changes";
        after = [ "${pkg.name}.service" "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        # Deliberately neither partOf nor requires docker.service: `docker
        # events` exits cleanly when the daemon goes away, and the watcher syncs
        # once before watching, so Restart = always recovers on its own. Docker
        # here is partOf libvirtd (see hosts/nixos/default.nix), so it restarts
        # more often than usual; clear the start rate limit so a long Docker
        # outage cannot make systemd give up on the watcher permanently.
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          User = cfg.syncUser;
          ExecStartPre = "${waitForCaddyAdmin}";
          ExecStart = "${exe} --watch";
          Restart = "always";
          RestartSec = 5;
        };
      })
    ];

  peerRoutes =
    lib.filterAttrs (_: routeCfg: routeCfg.syncer == "tailnet") cfg.routes;

  dockerRoutes =
    lib.filterAttrs (_: routeCfg: routeCfg.syncer == "docker") cfg.routes;

in {
  options.services.tailnetCaddy = {
    enable = lib.mkEnableOption "private HTTPS publishing through Caddy";

    listen = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ":443" ];
      example = [ "100.64.0.1:443" ];
      description = ''
        Caddy listener addresses for private HTTPS traffic. Use the default with
        the Tailscale firewall rule, or set an explicit Tailscale IP for
        socket-level binding.
      '';
    };

    cloudflareEnvironmentFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/caddy/cloudflare.env";
      description = ''
        Environment file containing CLOUDFLARE_API_TOKEN. Use a path on a
        persistent filesystem (not /run, which is tmpfs and cleared on reboot)
        unless a secrets manager recreates it on every boot.
      '';
    };

    routes = lib.mkOption {
      type = lib.types.attrsOf routeModule;
      default = { };
      description = "Wildcard HTTPS route sets served by private Caddy.";
    };

    syncUser = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        Account used by the syncers. The host configuration sets this to the
        primary user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.routes != { };
        message =
          "services.tailnetCaddy.routes must define at least one route set.";
      }
      {
        assertion =
          lib.all (routeName: builtins.match "[A-Za-z0-9_-]+" routeName != null)
          (lib.attrNames cfg.routes);
        message =
          "services.tailnetCaddy.routes names must contain only letters, numbers, underscores, and hyphens.";
      }
      {
        # The default listener binds :443 on all interfaces and relies on the
        # firewall to keep it tailnet-only. Only enforce this when an explicit
        # (socket-bound) listen address has not been supplied.
        assertion = !(lib.elem ":443" cfg.listen)
          || config.networking.firewall.enable;
        message =
          "services.tailnetCaddy uses the default :443 listener, which relies on the firewall to stay tailnet-only; either keep networking.firewall.enable, or set services.tailnetCaddy.listen to an explicit Tailscale address.";
      }
      {
        assertion = dockerRoutes == { } || config.virtualisation.docker.enable;
        message =
          "services.tailnetCaddy routes with syncer = \"docker\" read container labels from the local Docker daemon; either enable virtualisation.docker, or change the route's syncer.";
      }
    ];

    services.tailscale.enable = true;

    services.caddy = {
      enable = true;
      adapter = null;
      # A reload clears the Docker routes. Only a restart triggers the
      # oneshot syncer through PartOf.
      enableReload = false;
      environmentFile = cfg.cloudflareEnvironmentFile;
      package =
        assert lib.assertMsg (pkgs.caddy.version == caddyCloudflareHashCaddyVersion) ''
          nixpkgs has Caddy ${pkgs.caddy.version}, but caddyCloudflareHash in
          modules/nixos/caddy.nix is for Caddy ${caddyCloudflareHashCaddyVersion}.
          Set caddyCloudflareHashCaddyVersion to "${pkgs.caddy.version}" and
          caddyCloudflareHash to lib.fakeHash, rebuild, and copy the hash from
          the "got:" line of the hash mismatch error.'';
        pkgs.caddy.withPlugins {
          plugins =
            [ "github.com/caddy-dns/cloudflare@${caddyCloudflareVersion}" ];
          hash = caddyCloudflareHash;
        };
      settings = {
        admin.listen = "localhost:2019";
        # The peer syncers poll the admin API, which logs every request. This
        # also drops Caddy's log of rejected updates, so the syncers log
        # Caddy's error response instead.
        logging.logs.default.exclude = [ "admin.api" ];
        apps = {
          tls.automation.policies = map mkTlsPolicy (lib.attrValues cfg.routes);
          http.servers.tailnet = {
            listen = cfg.listen;
            automatic_https.disable_redirects = true;
            tls_connection_policies = [ { } ];
            routes = lib.mapAttrsToList mkHttpRoute cfg.routes;
          };
        };
      };
    };

    environment.systemPackages = (lib.mapAttrsToList mkPeerSyncPackage peerRoutes)
      ++ (lib.mapAttrsToList mkDockerSyncPackage dockerRoutes);

    systemd.services = builtins.listToAttrs
      ((lib.mapAttrsToList mkPeerSyncUnit peerRoutes)
        ++ (lib.concatLists (lib.mapAttrsToList mkDockerSyncUnits dockerRoutes)));

    # The Docker syncers run as syncUser rather than root, so they need group
    # access to the Docker socket. The Caddy admin API is already reachable by
    # any local user, so this is the only privilege they require.
    users.users = lib.mkIf (dockerRoutes != { }) {
      ${cfg.syncUser}.extraGroups = [ "docker" ];
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
  };
}
