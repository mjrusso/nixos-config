{ writeShellApplication }:

writeShellApplication {
  name = "voom-egress-skip";
  text = ''
    if [[ $# -gt 0 && $1 == -- ]]; then
      shift
    fi
    if [[ $# -eq 0 ]]; then
      echo "usage: voom-egress-skip -- command [argument ...]" >&2
      exit 2
    fi

    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
    unset NO_PROXY no_proxy
    unset SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE GIT_SSL_CAINFO
    unset NODE_EXTRA_CA_CERTS NODE_USE_ENV_PROXY DENO_CERT
    if [[ ''${GH_TOKEN:-} == __github_token__ ]]; then
      unset GH_TOKEN
    fi
    unset VOOM_EGRESS_ACTIVE
    export VOOM_EGRESS_SKIP=1

    exec "$@"
  '';
}
