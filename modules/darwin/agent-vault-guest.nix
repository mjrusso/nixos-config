{
  config,
  lib,
  pkgs,
  systemType,
  ...
}:
let
  cfg = config.programs.agentVaultProxy;
  bundle = "/etc/ssl/certs/ca-certificates.crt";
  noProxy = lib.concatStringsSep "," cfg.noProxy;
  environment = {
    HTTP_PROXY = cfg.url;
    HTTPS_PROXY = cfg.url;
    http_proxy = cfg.url;
    https_proxy = cfg.url;
    NO_PROXY = noProxy;
    no_proxy = noProxy;
    SSL_CERT_FILE = bundle;
    CURL_CA_BUNDLE = bundle;
    REQUESTS_CA_BUNDLE = bundle;
    GIT_SSL_CAINFO = bundle;
    NODE_EXTRA_CA_CERTS = toString cfg.caCertificate;
    NODE_USE_ENV_PROXY = "1";
    DENO_CERT = bundle;
  };
  helper = pkgs.callPackage ../../packages/agent-vault-proxy.nix {
    inherit environment;
    inherit (cfg) credentialFile;
  };
in
{
  options.programs.agentVaultProxy = {
    enable = lib.mkEnableOption "shared Agent Vault access in a macOS guest";
    url = lib.mkOption {
      type = lib.types.strMatching "http://[^/@]+:[0-9]+";
      description = "Proxy URL on the Mac host, without embedded credentials.";
    };
    credentialFile = lib.mkOption {
      type = lib.types.str;
      default = "~/.config/agent-vault-proxy/credential.json";
      description = "Private runtime JSON file containing the proxy identity and password.";
    };
    caCertificate = lib.mkOption {
      type = lib.types.path;
      description = "Public CA certificate from the Linux Agent Vault server.";
    };
    noProxy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = import ../../packages/voom-egress-no-proxy.nix;
      description = "Hosts reached directly from the guest.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = systemType == "vm";
        message = "Enable agentVaultProxy only in macOS guests.";
      }
    ];
    security.pki.certificateFiles = [ cfg.caCertificate ];
    system.activationScripts.postActivation.text = ''
      /usr/bin/security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain ${lib.escapeShellArg (toString cfg.caCertificate)}
    '';
    environment.variables = environment;
    environment.systemPackages = [
      helper
      (pkgs.callPackage ../../packages/proxy.nix {
        proxyCommand = [
          (lib.getExe helper)
          "run"
        ];
      })
    ];
    programs.fish.shellInit = lib.mkAfter ''
      ${lib.getExe helper} env --fish --if-present | source
    '';
  };
}
