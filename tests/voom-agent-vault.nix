{ pkgs, voomPackage }:

let
  testPkgs = pkgs.extend (
    _final: _previous: {
      voom = voomPackage;
    }
  );
in
testPkgs.testers.runNixOSTest {
  name = "voom-agent-vault";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../modules/nixos/voom-agent-vault.nix ];

      networking.firewall = {
        enable = true;
        backend = "iptables";
      };

      users.users.operator = {
        isNormalUser = true;
        uid = 1000;
      };

      services.voomAgentVault = {
        enable = true;
        user = "operator";
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
        pkgs.util-linux
      ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("voom-agent-vault-firewall.service")
    machine.wait_for_unit("agent-vault.service")
    machine.wait_for_unit("user@1000.service")
    machine.wait_until_succeeds(
      "runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user is-active --quiet voom-agent-vault-bridge.service"
    )
    machine.succeed("test -S /run/user/1000/voom-agent-vault/bridge-health.sock")
    machine.succeed(
      "test \"$(runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user show --property Type --value voom-agent-vault-bridge.service)\" = notify-reload"
    )
    machine.succeed("install -o operator -g users -m 0600 /dev/null /home/operator/bridge-secret")
    machine.succeed(
      "pid=$(runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user show --property MainPID --value voom-agent-vault-bridge.service); "
      "nsenter --target \"$pid\" --mount test ! -e /home/operator/bridge-secret"
    )
    machine.succeed("test \"$(stat -c %a /var/cache/agent-vault-backup)\" = 700")

    attachment_id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    attachment_dir = "/home/operator/.local/state/voom-agent-vault/attachments/" + attachment_id
    attachment_socket = "/run/user/1000/voom-agent-vault/" + attachment_id + ".sock"
    attachment = (
      '{"schemaVersion":1,"vmID":"' + attachment_id
      + '","lastKnownName":"reload-test","profile":"personal","vault":"personal",'
      + '"agentName":"voom-' + attachment_id.lower() + '","socket":"'
      + attachment_socket + '","desiredEnabled":false,"pendingOperation":null}'
    )
    machine.succeed(
      "install -d -o operator -g users -m 0700 " + attachment_dir + "; "
      "printf '%s\\n' '" + attachment + "' | "
      "install -o operator -g users -m 0600 /dev/stdin " + attachment_dir + "/attachment.json; "
      "printf '%s\\n' 'test-agent-token' | "
      "install -o operator -g users -m 0600 /dev/stdin " + attachment_dir + "/token"
    )
    machine.succeed(
      "runuser -u operator -- env HOME=/home/operator XDG_RUNTIME_DIR=/run/user/1000 "
      "voom-agent-vault --config /etc/voom-agent-vault/config.json render-bridge"
    )
    machine.succeed(
      "runuser -u operator -- env XDG_RUNTIME_DIR=/run/user/1000 "
      "systemctl --user reload voom-agent-vault-bridge.service"
    )
    machine.succeed("test -S " + attachment_socket)
    machine.succeed(
      "runuser -u operator -- python3 -c 'import socket; "
      "client = socket.socket(socket.AF_UNIX); client.settimeout(2); "
      "client.connect(\"" + attachment_socket + "\"); client.close()'"
    )

    verify = (
      "uid=$(id -u agent-vault); "
      "test \"$(iptables -t filter -S OUTPUT | sed -n '/^-A OUTPUT /p' | head -n1)\" "
      "= \"-A OUTPUT -m owner --uid-owner $uid -j VOOM_AGENT_VAULT\"; "
      "test \"$(ip6tables -t filter -S OUTPUT | sed -n '/^-A OUTPUT /p' | head -n1)\" "
      "= \"-A OUTPUT -m owner --uid-owner $uid -j VOOM_AGENT_VAULT\""
    )
    machine.succeed(verify)
    machine.fail(
      "runuser -u agent-vault -- curl --noproxy '*' --fail --connect-timeout 2 "
      "http://127.0.0.1:14321/health"
    )

    machine.succeed("ip address add 192.0.2.10/32 dev lo")
    machine.succeed("ip -6 address add 2001:db8::10/128 dev lo preferred_lft 60 valid_lft 120")
    machine.succeed(
      "python3 -m http.server 18080 --bind 0.0.0.0 >/tmp/http4.log 2>&1 & "
      "python3 -m http.server 18081 --bind :: >/tmp/http6.log 2>&1 &"
    )
    machine.wait_until_succeeds("curl --noproxy '*' --fail http://192.0.2.10:18080/")
    machine.wait_until_succeeds("curl --noproxy '*' --fail 'http://[2001:db8::10]:18081/'")
    for address in (
      "http://localhost:18080/",
      "http://192.0.2.10:18080/",
      "http://[::1]:18081/",
      "http://[2001:db8::10]:18081/",
    ):
        machine.fail(
          "runuser -u agent-vault -- curl --noproxy '*' --fail --connect-timeout 2 "
          + address
        )

    machine.succeed(
      "target=$(readlink -f /etc/resolv.conf); cp \"$target\" /tmp/resolv.conf.backup; "
      "printf 'nameserver 127.0.0.53\\n' >\"$target\""
    )
    machine.fail("systemctl start voom-agent-vault-firewall-check.service")
    machine.wait_until_fails("systemctl is-active --quiet agent-vault.service")
    machine.succeed("grep -Fq 'host-local resolver 127.0.0.53' /run/voom-agent-vault-firewall/status.json")
    machine.succeed(
      "target=$(readlink -f /etc/resolv.conf); cp /tmp/resolv.conf.backup \"$target\"; "
      "systemctl restart voom-agent-vault-firewall.service"
    )
    machine.wait_for_unit("agent-vault.service")
    machine.succeed(verify)

    machine.succeed("iptables -t filter -I OUTPUT 1 -j ACCEPT")
    machine.fail("systemctl start voom-agent-vault-firewall-check.service")
    machine.wait_until_fails("systemctl is-active --quiet agent-vault.service")
    machine.succeed("iptables -t filter -D OUTPUT 1")
    machine.succeed("systemctl restart voom-agent-vault-firewall.service")
    machine.wait_for_unit("agent-vault.service")
    machine.succeed(verify)

    machine.succeed("systemctl stop voom-agent-vault-firewall.service")
    machine.wait_until_fails("systemctl is-active --quiet agent-vault.service")
    machine.fail("systemctl start voom-agent-vault-firewall-check.service")
    machine.fail("systemctl is-active --quiet voom-agent-vault-firewall.service")
    machine.sleep(32)
    machine.fail("systemctl is-active --quiet voom-agent-vault-firewall.service")
    machine.succeed("systemctl restart voom-agent-vault-firewall.service")
    machine.wait_for_unit("agent-vault.service")
    machine.succeed(verify)

    machine.succeed(
      "install -d /run/systemd/system/firewall.service.d; "
      "printf '[Service]\\nExecReload=\\nExecReload=/run/current-system/sw/bin/false\\n' "
      ">/run/systemd/system/firewall.service.d/fail-reload.conf; "
      "systemctl daemon-reload"
    )
    machine.fail("systemctl reload firewall.service")
    machine.succeed(verify)
    machine.succeed("systemctl start voom-agent-vault-firewall-check.service")
    machine.succeed("systemctl is-active --quiet agent-vault.service")
    machine.succeed(
      "rm /run/systemd/system/firewall.service.d/fail-reload.conf; "
      "systemctl daemon-reload; systemctl restart firewall.service"
    )
    machine.wait_for_unit("voom-agent-vault-firewall.service")
    machine.wait_for_unit("agent-vault.service")
    machine.succeed(verify)

    machine.succeed("systemctl restart firewall.service")
    machine.wait_for_unit("voom-agent-vault-firewall.service")
    machine.wait_for_unit("agent-vault.service")
    machine.succeed(verify)
  '';
}
