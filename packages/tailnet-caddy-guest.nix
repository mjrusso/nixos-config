{
  lib,
  writeText,
  writeShellScript,
  writeShellApplication,
  caddy,
  coreutils,
  curl,
  jq,
  tailscale,
  runtimeDir,
  # Prints a JSON array of {addr, port, pid, process} objects.
  listListeners,
  # Prints the first and last port of the kernel's ephemeral range.
  ephemeralPorts,
}:

let
  port = import ./tailnet-caddy-guest-port.nix;
  adminSocket = "${runtimeDir}/admin.sock";
  routeId = "published";

  config = writeText "tailnet-caddy-guest.json" (builtins.toJSON {
    admin = {
      listen = "unix/${adminSocket}";
      config.persist = false;
    };
    apps.http.servers.tailnet = {
      listen = [ "{env.TAILNET_IP}:${toString port}" ];
      automatic_https.disable = true;
      routes = [
        { handle = [{ handler = "subroute"; "@id" = routeId; routes = [ ]; }]; }
        {
          handle = [{
            handler = "static_response";
            status_code = 404;
            body = "no published port\n";
          }];
        }
      ];
    };
  });
in
{
  start = writeShellScript "tailnet-caddy-guest" ''
    until TAILNET_IP="$(${lib.getExe tailscale} ip -4 2>/dev/null)"; do
      sleep 5
    done
    export TAILNET_IP
    ${coreutils}/bin/mkdir -p -m 0700 ${runtimeDir}
    export XDG_DATA_HOME=${runtimeDir}
    exec ${lib.getExe caddy} run --config ${config}
  '';

  sync = writeShellApplication {
    name = "tailnet-caddy-guest-sync";
    runtimeInputs = [ coreutils curl jq ];
    text = ''
      socket=${adminSocket}
      admin_url=http://localhost/id/${routeId}/routes

      dry_run=0
      case "''${1:-}" in
        "") ;;
        --dry-run) dry_run=1 ;;
        *) echo "usage: tailnet-caddy-guest-sync [--dry-run]" >&2; exit 2 ;;
      esac

      log() {
        echo "tailnet-caddy-guest-sync: $*" >&2
      }

      read -r ephemeral_first ephemeral_last < <(${ephemeralPorts})

      dial_address() {
        case "$1" in
          "*"|0.0.0.0|::) printf '127.0.0.1:%s\n' "$2" ;;
          *:*) printf '[%s]:%s\n' "$1" "$2" ;;
          *) printf '%s:%s\n' "$1" "$2" ;;
        esac
      }

      # Probe HTTPS first because a TLS listener can return 400 to plain HTTP.
      probe() {
        if curl --noproxy '*' -sk -o /dev/null --max-time 1 "https://$1/"; then
          echo https
        elif curl --noproxy '*' -s -o /dev/null --max-time 1 "http://$1/"; then
          echo http
        else
          echo none
        fi
      }

      declare -A scheme=() attempts=() next_probe=()

      # Command substitution would discard changes to the probe cache.
      build_routes() {
        local listeners now key address dial tries published="" route_list=()
        local -A seen=()

        listeners="$(${listListeners} | jq -r \
          --argjson skip '[22, ${toString port}]' \
          --argjson first "$ephemeral_first" \
          --argjson last "$ephemeral_last" '
            map(select(
              (.process | IN("tailscaled", ".tailscaled-wrapped", ".tailscaled-wra") | not)
              and (.port | IN($skip[]) | not)
              and ((.addr | test("^(127\\.|::1$)")) and .port >= $first and .port <= $last | not)
            ))
            | sort_by(.port, (.addr | test(":")))
            | .[]
            | "\(.port) \(.addr) \(.pid // "")"
          ')" || return 1
        now="$(date +%s)"

        while read -r port address pid; do
          [[ -n "$port" ]] || continue
          key="$port $address $pid"
          seen[$key]=1
          [[ " $published " != *" $port "* ]] || continue
          dial="$(dial_address "$address" "$port")"

          if [[ -z "''${scheme[$key]:-}" ]] ||
            [[ "''${scheme[$key]}" == none && "''${attempts[$key]}" -lt 4 && "$now" -ge "''${next_probe[$key]}" ]]; then
            scheme[$key]="$(probe "$dial")"
            tries=$(( ''${attempts[$key]:-0} + 1 ))
            attempts[$key]=$tries
            next_probe[$key]=$(( now + (5 << tries) ))
          fi
          [[ "''${scheme[$key]}" != none ]] || continue

          published+=" $port"
          route_list+=("$(jq -cn \
            --arg pattern "^[a-z0-9-]+-$port\\." \
            --arg dial "$dial" \
            --arg scheme "''${scheme[$key]}" '
              {
                match: [{vars_regexp: {"{http.request.host}": {pattern: $pattern}}}],
                handle: [
                  {handler: "reverse_proxy", stream_close_delay: "1h", upstreams: [{dial: $dial}]}
                  + if $scheme == "https" then
                      {transport: {protocol: "http", tls: {insecure_skip_verify: true}}}
                    else {} end
                ]
              }')")
        done <<<"$listeners"

        for key in "''${!scheme[@]}"; do
          if [[ -z "''${seen[$key]:-}" ]]; then
            unset 'scheme[$key]' 'attempts[$key]' 'next_probe[$key]'
          fi
        done

        want="$(printf '%s\n' "''${route_list[@]}" | jq -cS -s .)"
      }

      if [[ "$dry_run" -eq 1 ]]; then
        build_routes
        jq . <<<"$want"
        exit 0
      fi

      # The socket appears after the guest joins Tailscale.
      while :; do
        if [[ -S "$socket" ]]; then
          if ! build_routes; then
            log "could not list listeners"
          elif ! have="$(curl -fsS --unix-socket "$socket" "$admin_url" | jq -cS .)"; then
            log "could not read Caddy routes"
          elif [[ "$want" != "$have" ]]; then
            if curl -fsS --unix-socket "$socket" -X PATCH \
              -H 'Content-Type: application/json' \
              --data-binary "$want" "$admin_url" >/dev/null; then
              log "published $(jq length <<<"$want") port(s)"
            else
              log "could not patch Caddy routes"
            fi
          fi
        fi
        sleep 2
      done
    '';
  };
}
