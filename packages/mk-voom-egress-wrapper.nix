{
  lib,
  makeWrapper,
  symlinkJoin,
  voomEgressRun,
}:

{
  package,
  program,
}:

let
  executable = lib.getExe' package program;
  wrapperLogic = ''
    if [ "''${VOOM_EGRESS_SKIP:-}" != 1 ] \
      && [ "''${VOOM_EGRESS_ACTIVE:-}" != 1 ] \
      && [ -e /run/voom/egress.json ]; then
      exec ${lib.getExe voomEgressRun} -- ${executable} "$@"
    fi
  '';
in
symlinkJoin {
  name = "${package.name}-voom-egress";
  paths = [ package ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm "$out/bin/${program}"
    makeWrapper ${executable} "$out/bin/${program}" \
      --run ${lib.escapeShellArg wrapperLogic}
  '';
  inherit (package) meta;
}
