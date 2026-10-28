{
  callPackage,
  lib,
  writeShellApplication,
  proxyCommand ? [ (lib.getExe (callPackage ./voom-egress-run.nix { })) ],
}:
let
  bypass = callPackage ./voom-egress-skip.nix { };
in
writeShellApplication {
  name = "proxy";
  text = ''
    case "''${1:-}" in
      run)
        shift
        exec ${lib.escapeShellArgs proxyCommand} "$@"
        ;;
      bypass)
        shift
        exec ${lib.getExe bypass} "$@"
        ;;
      -h|--help)
        echo "usage: proxy {run|bypass} -- command [argument ...]"
        ;;
      *)
        echo "usage: proxy {run|bypass} -- command [argument ...]" >&2
        exit 2
        ;;
    esac
  '';
}
