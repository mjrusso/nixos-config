{
  cacert,
  coreutils,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "voom-egress-run";
  runtimeInputs = [
    coreutils
    jq
  ];
  text = ''
    manifest=/run/voom/egress.json
    if [[ ! -r "$manifest" ]]; then
      echo "voom-egress-run: brokered egress is disabled or unconfigured" >&2
      exit 1
    fi
    if [[ $# -gt 0 && $1 == -- ]]; then
      shift
    fi
    if [[ $# -eq 0 ]]; then
      echo "usage: voom-egress-run -- command [argument ...]" >&2
      exit 2
    fi

    jq -e '.schemaVersion == 1' "$manifest" >/dev/null || {
      echo "voom-egress-run: unsupported egress manifest" >&2
      exit 1
    }
    jq -e '.mode == "explicit"' "$manifest" >/dev/null || {
      echo "voom-egress-run: unsupported egress mode" >&2
      exit 1
    }
    http_proxy_url=$(jq -er '.httpProxy | strings | select(. == "http://192.168.127.1:3128")' "$manifest") || {
      echo "voom-egress-run: invalid HTTP proxy address" >&2
      exit 1
    }
    https_proxy_url=$(jq -er '.httpsProxy | strings | select(. == "http://192.168.127.1:3128")' "$manifest") || {
      echo "voom-egress-run: invalid HTTPS proxy address" >&2
      exit 1
    }
    ca_path=$(jq -er '.caCertificate // "" | strings' "$manifest") || {
      echo "voom-egress-run: invalid CA path" >&2
      exit 1
    }
    if [[ -z ''${XDG_RUNTIME_DIR:-} || ! -d $XDG_RUNTIME_DIR ]]; then
      echo "voom-egress-run: XDG_RUNTIME_DIR is unavailable" >&2
      exit 1
    fi
    runtime_dir="$XDG_RUNTIME_DIR/voom-egress"
    install -d -m 0700 "$runtime_dir"
    combined="$runtime_dir/ca-bundle.pem"
    temp=$(mktemp "$runtime_dir/ca-bundle.XXXXXX")
    if [[ -n $ca_path ]]; then
      if [[ $ca_path != /run/voom/egress-ca.pem || ! -r $ca_path ]]; then
        echo "voom-egress-run: declared CA is unavailable" >&2
        exit 1
      fi
      cat ${cacert}/etc/ssl/certs/ca-bundle.crt "$ca_path" > "$temp"
    else
      cat ${cacert}/etc/ssl/certs/ca-bundle.crt > "$temp"
    fi
    chmod 0600 "$temp"
    mv -f "$temp" "$combined"

    no_proxy_value=''${NO_PROXY:-''${no_proxy:-}}
    for entry in localhost 127.0.0.1 ::1; do
      case ",$no_proxy_value," in
        *",$entry,"*) ;;
        *) no_proxy_value="''${no_proxy_value:+$no_proxy_value,}$entry" ;;
      esac
    done

    export HTTP_PROXY="$http_proxy_url"
    export HTTPS_PROXY="$https_proxy_url"
    export http_proxy="$http_proxy_url"
    export https_proxy="$https_proxy_url"
    export NO_PROXY="$no_proxy_value"
    export no_proxy="$no_proxy_value"
    export SSL_CERT_FILE="$combined"
    export CURL_CA_BUNDLE="$combined"
    export REQUESTS_CA_BUNDLE="$combined"
    export GIT_SSL_CAINFO="$combined"
    export NODE_EXTRA_CA_CERTS="''${ca_path:-$combined}"
    export NODE_USE_ENV_PROXY=1
    export DENO_CERT="$combined"
    export GH_TOKEN="''${GH_TOKEN:-__github_token__}"
    export VOOM_EGRESS_ACTIVE=1
    exec "$@"
  '';
}
