{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gawk,
  jq,
}:

writeShellApplication {
  name = "disk-usage";
  runtimeInputs = [
    coreutils
    findutils
    gawk
    jq
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ../scripts/disk-usage);
  meta = {
    description = "Report disk usage and the commands that free reclaimable space";
    mainProgram = "disk-usage";
    platforms = lib.platforms.unix;
  };
}
