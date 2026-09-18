{
  cacert,
  coreutils,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "voom-egress-prepare";
  runtimeInputs = [
    coreutils
    jq
  ];
  text = ''
    set -euo pipefail

    allow_missing=false
    if [[ ''${1:-} == --allow-missing ]]; then
      allow_missing=true
      shift
    fi
    if [[ $# -ne 1 ]]; then
      echo "usage: voom-egress-prepare [--allow-missing] <runtime-directory>" >&2
      exit 2
    fi

    runtime_dir=$1
    case "$runtime_dir" in
      /run/voom-egress) mode=0755 ;;
      "''${XDG_RUNTIME_DIR:-}"/voom-egress)
        if [[ -z ''${XDG_RUNTIME_DIR:-} ]]; then
          echo "voom-egress-prepare: XDG_RUNTIME_DIR is unavailable" >&2
          exit 1
        fi
        mode=0700
        ;;
      *)
        echo "voom-egress-prepare: invalid runtime directory" >&2
        exit 1
        ;;
    esac

    install -d -m "$mode" "$runtime_dir"
    environment_file="$runtime_dir/environment"
    combined="$runtime_dir/ca-bundle.pem"
    manifest=/run/voom/egress.json
    rm -f "$environment_file"

    if [[ ! -r "$manifest" ]]; then
      rm -f "$combined"
      if [[ $allow_missing == true ]]; then
        exit 0
      fi
      echo "voom-egress-prepare: brokered egress is disabled or unconfigured" >&2
      exit 1
    fi

    jq -e '.schemaVersion == 1' "$manifest" >/dev/null || {
      echo "voom-egress-prepare: unsupported egress manifest" >&2
      exit 1
    }
    jq -e '.mode == "explicit"' "$manifest" >/dev/null || {
      echo "voom-egress-prepare: unsupported egress mode" >&2
      exit 1
    }
    http_proxy_url=$(jq -er '.httpProxy | strings | select(. == "http://192.168.127.1:3128")' "$manifest") || {
      echo "voom-egress-prepare: invalid HTTP proxy address" >&2
      exit 1
    }
    https_proxy_url=$(jq -er '.httpsProxy | strings | select(. == "http://192.168.127.1:3128")' "$manifest") || {
      echo "voom-egress-prepare: invalid HTTPS proxy address" >&2
      exit 1
    }
    ca_path=$(jq -er '.caCertificate // "" | strings' "$manifest") || {
      echo "voom-egress-prepare: invalid CA path" >&2
      exit 1
    }
    if [[ -n $ca_path && ( $ca_path != /run/voom/egress-ca.pem || ! -r $ca_path ) ]]; then
      echo "voom-egress-prepare: declared CA is unavailable" >&2
      exit 1
    fi

    combined_temp=$(mktemp "$runtime_dir/.ca-bundle.XXXXXX")
    environment_temp=$(mktemp "$runtime_dir/.environment.XXXXXX")
    cleanup() {
      rm -f "$combined_temp" "$environment_temp"
    }
    trap cleanup EXIT

    if [[ -n $ca_path ]]; then
      cat ${cacert}/etc/ssl/certs/ca-bundle.crt "$ca_path" > "$combined_temp"
    else
      cat ${cacert}/etc/ssl/certs/ca-bundle.crt > "$combined_temp"
    fi
    chmod 0644 "$combined_temp"

    node_ca="''${ca_path:-$combined}"
    printf '%s\n' \
      "HTTP_PROXY=$http_proxy_url" \
      "HTTPS_PROXY=$https_proxy_url" \
      "http_proxy=$http_proxy_url" \
      "https_proxy=$https_proxy_url" \
      "NO_PROXY=localhost,127.0.0.1,::1" \
      "no_proxy=localhost,127.0.0.1,::1" \
      "SSL_CERT_FILE=$combined" \
      "CURL_CA_BUNDLE=$combined" \
      "REQUESTS_CA_BUNDLE=$combined" \
      "GIT_SSL_CAINFO=$combined" \
      "NODE_EXTRA_CA_CERTS=$node_ca" \
      "NODE_USE_ENV_PROXY=1" \
      "DENO_CERT=$combined" \
      "GH_TOKEN=__github_token__" > "$environment_temp"
    chmod 0644 "$environment_temp"

    mv -f "$combined_temp" "$combined"
    mv -f "$environment_temp" "$environment_file"
    trap - EXIT
  '';
}
