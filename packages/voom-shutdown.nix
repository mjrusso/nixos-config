{
  lib,
  symlinkJoin,
  writeShellApplication,
  bash,
  coreutils,
  jq,
  voom,
}:

let
  runtimeInputs = [
    bash
    coreutils
    jq
    voom
  ];
  command = name: writeShellApplication {
    inherit name runtimeInputs;
    text = lib.removePrefix "#!/usr/bin/env bash\n" (
      builtins.readFile (../scripts + "/${name}")
    );
  };
in
symlinkJoin {
  name = "voom-shutdown";
  paths = map command [
    "voom-shutdown"
    "voom-shutdown-all"
  ];
  meta = {
    description = "Stop Herdr sessions before stopping Voom virtual machines";
    mainProgram = "voom-shutdown";
    platforms = lib.platforms.unix;
  };
}
