{
  callPackage,
  writeShellApplication,
}:

let
  voomEgressPrepare = callPackage ./voom-egress-prepare.nix { };
in
writeShellApplication {
  name = "voom-egress-run";
  text = ''
    if [[ $# -gt 0 && $1 == -- ]]; then
      shift
    fi
    if [[ $# -eq 0 ]]; then
      echo "usage: voom-egress-run -- command [argument ...]" >&2
      exit 2
    fi

    if [[ -z ''${XDG_RUNTIME_DIR:-} || ! -d $XDG_RUNTIME_DIR ]]; then
      echo "voom-egress-run: XDG_RUNTIME_DIR is unavailable" >&2
      exit 1
    fi
    runtime_dir="$XDG_RUNTIME_DIR/voom-egress"

    no_proxy_value=''${NO_PROXY:-''${no_proxy:-}}
    github_token=''${GH_TOKEN:-}
    ${voomEgressPrepare}/bin/voom-egress-prepare "$runtime_dir"
    while IFS='=' read -r name value; do
      case "$name" in
        HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy|\
        SSL_CERT_FILE|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE|GIT_SSL_CAINFO|\
        NODE_EXTRA_CA_CERTS|NODE_USE_ENV_PROXY|DENO_CERT|GH_TOKEN)
          export "$name=$value"
          ;;
        *)
          echo "voom-egress-run: invalid environment entry" >&2
          exit 1
          ;;
      esac
    done < "$runtime_dir/environment"

    for entry in localhost 127.0.0.1 ::1; do
      case ",$no_proxy_value," in
        *",$entry,"*) ;;
        *) no_proxy_value="''${no_proxy_value:+$no_proxy_value,}$entry" ;;
      esac
    done

    export NO_PROXY="$no_proxy_value"
    export no_proxy="$no_proxy_value"
    export GH_TOKEN="''${github_token:-$GH_TOKEN}"
    exec "$@"
  '';
}
