{ pkgs, inputs }:
let
  system = inputs.darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    specialArgs = {
      voom = inputs.voom;
      userInfo = { user = "operator"; };
    };
    modules = [
      ../modules/darwin/vm.nix
      { system.stateVersion = 4; }
    ];
  };
  daemon = system.config.launchd.daemons.voom-guest-services.serviceConfig;
  arguments = daemon.ProgramArguments;
in
assert builtins.elem "/bin/sh" arguments;
assert builtins.any (argument: pkgs.lib.hasInfix "/bin/wait4path /nix/store && exec " argument) arguments;
assert pkgs.lib.hasInfix "voom-guest-control-v1" daemon.EnvironmentVariables.PYTHONPATH;
pkgs.runCommand "check-macos-guest-launchd" { } ''
  printf '%s\n' '${builtins.unsafeDiscardStringContext (builtins.toJSON arguments)}' > $out
''
