{ inputs, pkgs }:
let
  constructors = import ../lib { inherit inputs; };
  configuration =
    systemType:
    (constructors.mkDarwinConfiguration {
      inherit systemType;
      userInfo = {
        user = "test";
        name = "Test User";
        email = "test@example.com";
        sshKeys = [ ];
      };
    }).config;
  checkPackages =
    guest: packages:
    builtins.all
      (
        spec:
        let
          wrapper = builtins.head (builtins.filter (p: (p.name or "") == spec.name) packages);
        in
        pkgs.lib.hasInfix spec.flag wrapper.text == guest
      )
      [
        {
          name = "codex";
          flag = "--yolo";
        }
        {
          name = "claude";
          flag = "--dangerously-skip-permissions";
        }
      ];
  check =
    systemType:
    let
      config = configuration systemType;
      guest = systemType == "vm";
    in
    checkPackages guest config.environment.systemPackages
    && checkPackages guest config.home-manager.users.test.home.packages;
in
assert builtins.all check [
  "vm"
  "desktop"
  "laptop"
];
pkgs.runCommand "check-llm-agent-policy" { } ''
  touch $out
''
