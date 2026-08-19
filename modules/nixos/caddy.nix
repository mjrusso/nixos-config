{ config, pkgs, lib, ... }:

let
  cfg = config.services.tailnetCaddy;
  caddyCloudflareVersion = "v0.2.4";
  caddyCloudflareHash = "sha256-7GoH8YLCoPmPExQxoga2FHB58zQDoZVf1BBwkVi0SsQ=";

  routeModule = lib.types.submodule {
    options = {
      domain = lib.mkOption {
        type = lib.types.str;
        description = "Base DNS domain for this private Caddy route set.";
      };

      syncer = lib.mkOption {
        type = lib.types.enum [ "voom" "docker" "none" ];
        default = "voom";
        description = ''
          Which syncer owns this route's dynamic route list. Exactly one unit
          may PATCH a given route's subroute, so this also selects which unit is
          generated: "voom" publishes Voom forwards, "docker" publishes Docker
          containers labelled `caddy.host`, and "none" generates no syncer,
          leaving the route empty for ad-hoc PATCHes.
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

  mkVoomSyncPackage = routeName: routeCfg:
    let
      commandName = if routeName == "voom" then
        "voom-caddy-sync"
      else
        "voom-caddy-sync-${routeName}";
    in pkgs.writeShellApplication {
      name = commandName;
      runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
      text = ''
        set -euo pipefail

        usage() {
          cat <<'EOF'
        Usage: ${commandName} [options]

        Sync installed Voom HTTP(S) forwards into this route's Caddy route list.

        Options:
          --admin URL             Caddy admin API URL (default: http://localhost:2019)
          --voom PATH             Voom executable (default: voom)
          --vm NAME               Limit sync to one VM
          --all-tcp               Publish every installed non-SSH TCP forward without probing
          --include-manual        Include manual forwards (default: only auto forwards)
          --dry-run               Print generated routes instead of patching Caddy
          --timeout SECONDS       HTTP probe timeout (default: 1)
          --help                  Show this help

        Generated hostnames are:
          <vm>-<guest-port>.${routeCfg.domain}
        EOF
        }

        admin_url="http://localhost:2019"
        route_id=${lib.escapeShellArg (routeId routeName)}
        voom_bin="voom"
        domain=${lib.escapeShellArg routeCfg.domain}
        vm_name=""
        all_tcp=0
        include_manual=0
        dry_run=0
        probe_timeout=1

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --admin)
              admin_url="''${2:?missing value for --admin}"
              shift 2
              ;;
            --voom)
              voom_bin="''${2:?missing value for --voom}"
              shift 2
              ;;
            --vm)
              vm_name="''${2:?missing value for --vm}"
              shift 2
              ;;
            --all-tcp)
              all_tcp=1
              shift
              ;;
            --include-manual)
              include_manual=1
              shift
              ;;
            --dry-run)
              dry_run=1
              shift
              ;;
            --timeout)
              probe_timeout="''${2:?missing value for --timeout}"
              shift 2
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

        dns_label() {
          local label="$1"

          label="''${label,,}"
          label="''${label//_/-}"

          if [[ ''${#label} -gt 63 || ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            return 1
          fi

          printf '%s\n' "$label"
        }

        dial_host() {
          case "$1" in
            ""|"*"|"0.0.0.0"|"::"|"[::]")
              printf '127.0.0.1\n'
              ;;
            *)
              printf '%s\n' "$1"
              ;;
          esac
        }

        format_authority() {
          if [[ "$1" == *:* && "$1" != \[*\] ]]; then
            printf '[%s]:%s\n' "$1" "$2"
          else
            printf '%s:%s\n' "$1" "$2"
          fi
        }

        is_http() {
          local scheme="$1"
          local authority="$2"
          local host="$3"
          local tls_flag=()

          if [[ "$scheme" == "https" ]]; then
            tls_flag=(-k)
          fi

          # No -f: any HTTP response (including 401/403/404) means the upstream
          # speaks HTTP and should be published; -f would skip auth-gated apps
          # and apps without a root route.
          curl -sS "''${tls_flag[@]}" \
            --max-time "$probe_timeout" \
            -H "Host: $host" \
            -o /dev/null \
            "$scheme://$authority/" >/dev/null 2>&1
        }

        if ! command -v "$voom_bin" >/dev/null 2>&1; then
          echo "required command not found: $voom_bin" >&2
          exit 1
        fi

        voom_args=(forward ls --output json)
        if [[ -n "$vm_name" ]]; then
          voom_args+=("$vm_name")
        fi

        forwards="$("$voom_bin" "''${voom_args[@]}")"
        route_file="$(mktemp "''${TMPDIR:-/tmp}/voom-caddy-routes.XXXXXX")"
        trap 'rm -f "$route_file"' EXIT

        while IFS= read -r forward; do
          vm="$(jq -r '.vm' <<<"$forward")"
          bind="$(jq -r '.bind // ""' <<<"$forward")"
          host_port="$(jq -r '.hostPort | tostring' <<<"$forward")"
          guest_port="$(jq -r '.guestPort | tostring' <<<"$forward")"

          [[ -n "$vm" ]] || continue

          vm_label="$(dns_label "$vm")" || {
            echo "skipping forward with VM name that is not a DNS label: $vm" >&2
            continue
          }

          upstream_host="$(dial_host "$bind")"
          upstream_authority="$(format_authority "$upstream_host" "$host_port")"
          host="$vm_label-$guest_port.$domain"
          scheme=""

          if [[ "$all_tcp" -eq 1 ]]; then
            scheme="http"
          elif is_http http "$upstream_authority" "$host"; then
            scheme="http"
          elif is_http https "$upstream_authority" "$host"; then
            scheme="https"
          else
            continue
          fi

          jq -cn \
            --arg host "$host" \
            --arg dial "$upstream_authority" \
            --arg scheme "$scheme" \
            '{
              match: [{host: [$host]}],
              handle: [{
                handler: "reverse_proxy",
                upstreams: [{dial: $dial}]
              }]
            }
            | if $scheme == "https" then
                .handle[0].transport = {
                  protocol: "http",
                  tls: {insecure_skip_verify: true}
                }
              else
                .
              end' >>"$route_file"
        done < <(
          jq -r \
            --argjson include_manual "$include_manual" \
            '
              map(select(
                .installed == true
                and .protocol == "tcp"
                and .guestPort != 22
                and (($include_manual == 1) or .kind == "auto")
              ))[]
              | {
                  vm,
                  bind,
                  hostPort,
                  guestPort
                }
              | @json
            ' <<<"$forwards"
        )

        routes="$(jq -s . "$route_file")"

        if [[ "$dry_run" -eq 1 ]]; then
          jq . <<<"$routes"
          exit 0
        fi

        status="$(curl -sS -o /dev/null -w '%{http_code}' "$admin_url/id/$route_id/routes" || true)"
        case "$status" in
          200)
            ;;
          404)
            echo "Caddy route target @id=$route_id does not exist" >&2
            exit 1
            ;;
          *)
            echo "could not inspect Caddy route target @id=$route_id: HTTP $status" >&2
            exit 1
            ;;
        esac

        curl -fsS -X PATCH \
          -H 'Content-Type: application/json' \
          --data-binary "$routes" \
          "$admin_url/id/$route_id/routes" >/dev/null

        count="$(jq 'length' <<<"$routes")"
        echo "synced $count Caddy route(s) from Voom forwards"
      '';
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
              | { handler: "reverse_proxy", upstreams: [ { dial: .dial } ] } as $proxy
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

          curl -fsS -X PATCH \
            -H 'Content-Type: application/json' \
            --data-binary "$routes" \
            "$admin_url/id/$route_id/routes" >/dev/null

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

  mkVoomSyncUnit = routeName: routeCfg:
    let
      pkg = mkVoomSyncPackage routeName routeCfg;
      # Voom reads live VM/forward state from the user's runtime dir, but a
      # User= service does not inherit the login session's XDG_RUNTIME_DIR.
      # Derive it from the runtime UID (the service runs as syncUser, so `id -u`
      # is correct). Only export it when the dir exists: with no login session
      # the dir is absent, and pointing Voom at a missing dir makes it try to
      # create it and fail; leaving it unset makes Voom report no live forwards
      # (sync 0), which is the right answer when nothing is running.
      runner = pkgs.writeShellScript "${pkg.name}-run" ''
        rt="/run/user/$(${pkgs.coreutils}/bin/id -u)"
        if [ -d "$rt" ]; then
          export XDG_RUNTIME_DIR="$rt"
        fi
        exec ${pkg}/bin/${pkg.name} --voom ${pkgs.voom}/bin/voom
      '';
    in lib.nameValuePair pkg.name {
      description = "Re-seed Caddy '${routeName}' routes from Voom forwards";
      # Caddy reseeds the dynamic route list to empty whenever it starts —
      # including the config-change restart forced by enableReload = false below —
      # so re-run the sync on every Caddy start and restart to keep routes in sync
      # across reboots, manual restarts, and rebuilds.
      after = [ "caddy.service" ];
      requires = [ "caddy.service" ];
      wantedBy = [ "caddy.service" ]; # start with Caddy (e.g. at boot)
      partOf = [ "caddy.service" ]; # and re-run when Caddy restarts
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.syncUser;
        ExecStartPre = "${waitForCaddyAdmin}";
        ExecStart = "${runner}";
      };
    };

  # Two units per Docker route: a oneshot that re-seeds on every Caddy start
  # (Caddy empties the dynamic route list whenever it starts, exactly as for
  # Voom), and a watcher that keeps the list current between those restarts.
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

  # Each route's subroute is PATCHed by exactly one syncer, so the route set is
  # partitioned before any unit or package is generated: without this, a Docker
  # route would also get a Voom syncer that wipes its routes on every restart.
  voomRoutes = lib.filterAttrs (_: routeCfg: routeCfg.syncer == "voom") cfg.routes;

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
        User account whose Voom forwards are published. Voom state is per-user,
        so the auto-sync service that re-seeds Caddy's dynamic route list on every
        Caddy (re)start runs as this account. In this repo it is set automatically
        from the host's primary user.
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
      # Restart (not reload) on declarative config changes. A reload reseeds the
      # dynamic route list to empty without restarting voom-caddy-sync, leaving a
      # window with no routes; a restart lets partOf re-run the sync afterward.
      enableReload = false;
      environmentFile = cfg.cloudflareEnvironmentFile;
      package = pkgs.caddy.withPlugins {
        plugins =
          [ "github.com/caddy-dns/cloudflare@${caddyCloudflareVersion}" ];
        hash = caddyCloudflareHash;
      };
      settings = {
        admin.listen = "localhost:2019";
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

    environment.systemPackages = (lib.mapAttrsToList mkVoomSyncPackage voomRoutes)
      ++ (lib.mapAttrsToList mkDockerSyncPackage dockerRoutes);

    systemd.services = builtins.listToAttrs
      ((lib.mapAttrsToList mkVoomSyncUnit voomRoutes)
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
