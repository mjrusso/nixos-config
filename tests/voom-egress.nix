{ inputs, pkgs }:

let
  system = pkgs.stdenv.hostPlatform.system;
  testPkgs = import inputs.nixpkgs {
    inherit system;
    config = {
      allowBroken = true;
      allowUnfree = true;
      allowUnsupportedSystem = true;
    };
    overlays = [
      (_final: _previous: {
        my-emacs-with-packages = inputs.emacs-flake.packages.${system}.default;
        voom = inputs.voom.packages.${system}.default;
        herdlord = inputs.herdlord.packages.${system}.default;
        agent-browser = inputs.llm-agents.packages.${system}.agent-browser;
        herdr = inputs.llm-agents.packages.${system}.herdr;
      })
    ];
  };
  userInfo = {
    user = "operator";
    name = "Operator";
    email = "operator@example.com";
    sshKeys = [ ];
  };
  baseModule =
    { lib, pkgs, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        ../modules/container/voom-egress.nix
      ];

      _module.args = { inherit userInfo; };

      fileSystems."/run/voom" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=0755" ];
      };

      systemd.tmpfiles.rules = [ "d /run/voom 0755 root root -" ];

      services.cloud-init.enable = lib.mkForce false;

      programs.fish.enable = true;

      environment.systemPackages = [ pkgs.nss.tools ];

      users.users.operator = {
        isNormalUser = true;
        uid = 1000;
        shell = pkgs.fish;
      };

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit userInfo; };
        users.operator = import ../modules/container/home-manager.nix;
      };

      system.stateVersion = "24.11";

      virtualisation = {
        cores = 2;
        memorySize = 1536;
      };
    };
  validManifestModule =
    { pkgs, ... }:
    {
      systemd.services.test-voom-egress-manifest = {
        requiredBy = [ "voom-egress-trust.service" ];
        requires = [ "systemd-tmpfiles-setup.service" ];
        after = [
          "run-voom.mount"
          "systemd-tmpfiles-setup.service"
        ];
        before = [ "voom-egress-trust.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          key=$(${pkgs.coreutils}/bin/mktemp)
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
            -days 1 -subj /CN=Voom-Egress-Test -keyout "$key" \
            -out /run/voom/egress-ca.pem 2>/dev/null
          ${pkgs.coreutils}/bin/rm "$key"
          ${pkgs.coreutils}/bin/chmod 0644 /run/voom/egress-ca.pem
          ${pkgs.coreutils}/bin/printf '%s\n' \
            '{"schemaVersion":1,"mode":"explicit","httpProxy":"http://192.168.127.1:3128","httpsProxy":"http://192.168.127.1:3128","caCertificate":"/run/voom/egress-ca.pem"}' \
            > /run/voom/egress.json
          ${pkgs.coreutils}/bin/chmod 0644 /run/voom/egress.json
        '';
      };
    };
  invalidManifestModule =
    { pkgs, ... }:
    {
      systemd.services.test-voom-egress-manifest = {
        requiredBy = [ "voom-egress-trust.service" ];
        requires = [ "systemd-tmpfiles-setup.service" ];
        after = [
          "run-voom.mount"
          "systemd-tmpfiles-setup.service"
        ];
        before = [ "voom-egress-trust.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/printf '{}\n' > /run/voom/egress.json
          ${pkgs.coreutils}/bin/chmod 0644 /run/voom/egress.json
        '';
      };
    };
in
testPkgs.testers.runNixOSTest {
  name = "voom-egress";

  nodes = {
    attached.imports = [
      baseModule
      validManifestModule
    ];
    unattached.imports = [ baseModule ];
    invalid.imports = [
      baseModule
      invalidManifestModule
    ];
  };

  testScript = ''
    start_all()

    attached.wait_for_unit("multi-user.target")
    attached.wait_for_unit("home-manager-operator.service")
    attached.wait_for_unit("voom-egress-trust.service")
    attached.wait_for_unit("systemd-user-sessions.service")
    attached.succeed("test -r /run/voom-egress/environment")
    attached.succeed("test -r /run/voom-egress/ca-bundle.pem")
    attached.succeed("grep -Fx 'HTTP_PROXY=http://192.168.127.1:3128' /run/voom-egress/environment")
    attached.succeed("grep -Fx 'GH_TOKEN=__github_token__' /run/voom-egress/environment")
    attached.succeed("test \"$(stat -c %a /run/voom-egress/environment)\" = 644")
    attached.succeed("certutil -d sql:/home/operator/.pki/nssdb -L -n voom-egress")

    attached.succeed(
      "runuser -u operator -- env HOME=/home/operator fish -c "
      "'test \"$HTTP_PROXY\" = http://192.168.127.1:3128; "
      "test \"$NO_PROXY\" = localhost,127.0.0.1,::1; "
      "test \"$no_proxy\" = localhost,127.0.0.1,::1; "
      "test \"$SSL_CERT_FILE\" = /run/voom-egress/ca-bundle.pem; "
      "test \"$GH_TOKEN\" = __github_token__'"
    )
    attached.succeed(
      "runuser -u operator -- env HOME=/home/operator GH_TOKEN=__github_some_org_pat__ fish -c "
      "'test \"$GH_TOKEN\" = __github_some_org_pat__'"
    )

    attached.succeed("systemctl start user@1000.service")
    attached.wait_for_unit("user@1000.service")
    attached.succeed(
      "runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user show-environment | grep -Fx 'HTTP_PROXY=http://192.168.127.1:3128'"
    )
    attached.succeed(
      "runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user show-environment | grep -Fx 'GH_TOKEN=__github_token__'"
    )
    attached.succeed(
      "runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user show-environment | grep -Fx 'NO_PROXY=localhost,127.0.0.1,::1'"
    )

    attached.succeed(
      "test -x /etc/profiles/per-user/operator/bin/git; "
      "git_path=$(readlink -f /etc/profiles/per-user/operator/bin/git); "
      "case \"$git_path\" in *voom-egress*) exit 1;; esac"
    )
    attached.succeed(
      "test -x /etc/profiles/per-user/operator/bin/gh; "
      "gh_path=$(readlink -f /etc/profiles/per-user/operator/bin/gh); "
      "case \"$gh_path\" in *voom-egress*) exit 1;; esac"
    )
    attached.succeed(
      "test -x /etc/profiles/per-user/operator/bin/codex; "
      "codex_path=$(readlink -f /etc/profiles/per-user/operator/bin/codex); "
      "grep -Fq -- '--yolo' \"$codex_path\"; "
      "! grep -Fq voom-egress-run \"$codex_path\""
    )
    attached.succeed(
      "test -x /etc/profiles/per-user/operator/bin/claude; "
      "claude_path=$(readlink -f /etc/profiles/per-user/operator/bin/claude); "
      "grep -Fq -- '--dangerously-skip-permissions' \"$claude_path\"; "
      "! grep -Fq voom-egress-run \"$claude_path\""
    )

    attached.succeed(
      "runuser -u operator -- env HOME=/home/operator XDG_RUNTIME_DIR=/run/user/1000 "
      "GH_TOKEN=__github_some_org_pat__ voom-egress-run -- sh -c "
      "'test \"$HTTPS_PROXY\" = http://192.168.127.1:3128; "
      "test \"$NO_PROXY\" = localhost,127.0.0.1,::1; "
      "test \"$GH_TOKEN\" = __github_some_org_pat__'"
    )
    attached.succeed(
      "env HTTP_PROXY=http://192.168.127.1:3128 SSL_CERT_FILE=/run/voom-egress/ca-bundle.pem "
      "GH_TOKEN=__github_token__ voom-egress-skip -- sh -c "
      "'test -z \"''${HTTP_PROXY+x}\"; test -z \"''${SSL_CERT_FILE+x}\"; "
      "test -z \"''${GH_TOKEN+x}\"'"
    )

    unattached.wait_for_unit("multi-user.target")
    unattached.wait_for_unit("home-manager-operator.service")
    unattached.wait_for_unit("voom-egress-trust.service")
    unattached.wait_for_unit("systemd-user-sessions.service")
    unattached.succeed("test ! -e /run/voom-egress/environment")
    unattached.succeed(
      "runuser -u operator -- env -u HTTP_PROXY -u HTTPS_PROXY -u GH_TOKEN "
      "HOME=/home/operator fish -c "
      "'not set -q HTTP_PROXY; and not set -q HTTPS_PROXY; and not set -q GH_TOKEN'"
    )
    unattached.succeed("systemctl start user@1000.service")
    unattached.wait_for_unit("user@1000.service")
    unattached.fail(
      "runuser -u operator -- env HOME=/home/operator XDG_RUNTIME_DIR=/run/user/1000 "
      "voom-egress-run -- true 2>/tmp/voom-egress-run-error"
    )
    unattached.succeed(
      "grep -Fx 'voom-egress-prepare: brokered egress is disabled or unconfigured' "
      "/tmp/voom-egress-run-error"
    )

    invalid.wait_for_unit("multi-user.target")
    invalid.wait_until_succeeds("systemctl is-failed --quiet voom-egress-trust.service")
    invalid.fail("systemctl is-active --quiet systemd-user-sessions.service")
    invalid.succeed("test -e /run/nologin")
    invalid.succeed("test ! -e /run/voom-egress/environment")
  '';
}
