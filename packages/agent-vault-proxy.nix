{
  callPackage,
  curl,
  lib,
  python3,
  writeShellApplication,
  writeText,
  environment,
  credentialFile,
}:
let
  direct = callPackage ./voom-egress-skip.nix { };
  settings = writeText "agent-vault-proxy.json" (
    builtins.toJSON {
      inherit environment credentialFile;
      url = environment.HTTPS_PROXY;
      curl = lib.getExe curl;
      direct = lib.getExe direct;
    }
  );
in
writeShellApplication {
  name = "agent-vault-proxy";
  text = ''
    exec ${lib.getExe python3} ${./agent-vault-proxy.py} ${settings} "$@"
  '';
}
