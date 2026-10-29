{ pkgs, voomPackage }:
let
  testPkgs = pkgs.extend (_: _: { voom = voomPackage; });
  backend = pkgs.writeText "proxy-backend.py" ''
    import http.server
    import json
    import os
    import pathlib
    import socketserver
    import threading

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            body = json.dumps({
                "auth": self.headers.get_all("Proxy-Authorization"),
                "authorization": self.headers.get("Authorization"),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_CONNECT(self):
            self.send_response(200)
            self.send_header("X-Test-Auth", self.headers.get("Proxy-Authorization", ""))
            self.end_headers()
            while data := self.rfile.read1(4096):
                self.wfile.write(data)
                self.wfile.flush()

    other_path = "/var/lib/voom-agent-vault-public/unrelated.sock"
    pathlib.Path(other_path).unlink(missing_ok=True)
    other = socketserver.UnixStreamServer(other_path, Handler)
    os.chmod(other_path, 0o666)
    threading.Thread(target=other.serve_forever, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", 14322), Handler).serve_forever()
  '';
  connectProbe = pkgs.writeText "proxy-connect-probe.py" ''
    import base64
    from pathlib import Path
    import socket
    import sys

    auth = base64.b64encode(sys.argv[1].encode())
    with socket.create_connection(("127.0.0.1", 13128), timeout=15) as connection:
        connection.sendall(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: Basic " + auth + b"\r\n\r\n")
        response = b""
        while not response.endswith(b"\r\n\r\n"):
            chunk = connection.recv(1)
            assert chunk, response
            response += chunk
        assert b"200" in response and sys.argv[2].encode() in response, response
        connection.sendall(b"alive")
        assert connection.recv(5) == b"alive"
        if len(sys.argv) > 3:
            Path("/tmp/proxy-ready").touch()
            assert connection.recv(1) == b""
            Path("/tmp/proxy-closed").touch()
  '';
in
testPkgs.testers.runNixOSTest {
  name = "agent-vault-shared-proxy";
  nodes.machine = { lib, pkgs, ... }: {
    imports = [ ../modules/nixos/voom-agent-vault.nix ];
    users.users.operator.isNormalUser = true;
    services.voomAgentVault = {
      enable = true;
      user = "operator";
      sharedProxy = {
        enable = false;
        vaults = {
          personal.tokenFile = "/etc/personal-token";
          work.tokenFile = "/etc/work-token";
        };
        identities = {
          personal-dev = {
            vault = "personal";
            passwordFile = "/etc/personal-password";
          };
          personal-test = {
            vault = "personal";
            passwordFile = "/etc/test-password";
          };
          work = {
            vault = "work";
            passwordFile = "/etc/work-password";
          };
        };
      };
    };
    environment.etc =
      lib.genAttrs [ "personal-token" "work-token" "personal-password" "test-password" "work-password" ]
        (name: {
          text = name + "\n";
          mode = "0600";
        });
    systemd.services.agent-vault.serviceConfig = {
      ExecStart = lib.mkForce "${pkgs.python3}/bin/python3 ${backend}";
      ExecStartPost = lib.mkForce [ ];
    };
    specialisation.with-shared-proxy.configuration.services.voomAgentVault.sharedProxy.enable =
      lib.mkForce true;
    specialisation.no-access.configuration.services.voomAgentVault.sharedProxy = {
      enable = lib.mkForce true;
      vaults = lib.mkForce { };
      identities = lib.mkForce { };
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
      pkgs.openssh
    ];
    networking.firewall.backend = "iptables";
    system.stateVersion = "25.11";
  };
  testScript = ''
    import base64
    import json

    machine.start()
    machine.wait_for_unit("agent-vault.service")
    vault_pid = machine.succeed("systemctl show -p MainPID --value agent-vault.service")
    machine.fail("systemctl cat agent-vault-shared-proxy.service")
    machine.succeed("/run/current-system/specialisation/with-shared-proxy/bin/switch-to-configuration test")
    assert machine.succeed("systemctl show -p MainPID --value agent-vault.service") == vault_pid
    machine.wait_for_unit("agent-vault-shared-proxy.service")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    machine.wait_for_unit("sshd.service")
    machine.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /tmp/proxy-key")
    machine.succeed("install -m 0644 /tmp/proxy-key.pub /var/lib/agent-vault-shared-proxy/authorized_keys")
    ssh = "ssh -F /dev/null -i /tmp/proxy-key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    destination = "agent-vault-tunnel@127.0.0.1"
    machine.succeed(ssh + " -fNT -o ExitOnForwardFailure=yes -o ControlMaster=yes -o ControlPath=/tmp/proxy-control -L 127.0.0.1:13128:/run/agent-vault-shared-proxy/proxy.sock " + destination)
    curl = "curl --noproxy \"\" --silent --show-error --max-time 5 -x http://127.0.0.1:13128"
    personal = "Basic " + base64.b64encode(b"personal-token:personal").decode()
    work = "Basic " + base64.b64encode(b"work-token:work").decode()
    for login, expected in [("personal-dev:personal-password", personal), ("personal-test:test-password", personal), ("work:work-password", work)]:
        response = json.loads(machine.succeed(curl + " --fail --proxy-user " + login + " --header 'Authorization: Bearer placeholder' http://unused.invalid/"))
        assert response == {"auth": [expected], "authorization": "Bearer placeholder"}, response
    for auth in ["", " --proxy-user personal-dev:wrong", " --proxy-user unknown:personal-password", " --proxy-header 'Proxy-Authorization: " + work + "'"]:
        result = machine.succeed(curl + auth + " -o /dev/null -w '%{http_code}' http://unused.invalid/")
        assert result == "407", result
    guest_auth = base64.b64encode(b"personal-dev:personal-password").decode()
    duplicate = " --proxy-header 'Proxy-Authorization: Basic " + guest_auth + "' --proxy-header 'proxy-authorization: Basic " + guest_auth + "'"
    assert machine.succeed(curl + duplicate + " -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    status, output = machine.execute(curl + " --proxytunnel --proxy-user personal-dev:wrong -o /dev/null -w '%{http_connect}' http://unused.invalid/")
    assert status != 0 and "407" in output, output
    machine.succeed("systemctl restart agent-vault.service")
    machine.wait_for_unit("agent-vault-shared-proxy.service")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    machine.succeed("python3 ${connectProbe} personal-dev:personal-password '" + personal + "'")
    machine.succeed("systemd-run --unit=held-proxy python3 ${connectProbe} personal-dev:personal-password '" + personal + "' hold")
    machine.wait_until_succeeds("test -f /tmp/proxy-ready")
    machine.succeed("agent-vault-access disable personal-dev")
    machine.wait_until_succeeds("test -f /tmp/proxy-closed")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    assert "personal-dev\tpersonal\tdisabled" in machine.succeed("agent-vault-access status")
    assert machine.succeed(curl + " --proxy-user personal-dev:personal-password -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    exported = json.loads(machine.succeed("agent-vault-access export personal-dev"))
    assert exported == {"identity": "personal-dev", "password": "personal-password"}, exported
    machine.succeed(curl + " --fail --proxy-user personal-test:test-password http://unused.invalid/")
    machine.succeed(curl + " --fail --proxy-user work:work-password http://unused.invalid/")
    machine.succeed("systemctl restart agent-vault-shared-proxy.service")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    assert machine.succeed(curl + " --proxy-user personal-dev:personal-password -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    machine.succeed("agent-vault-access enable personal-dev")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    machine.succeed(curl + " --fail --proxy-user personal-dev:personal-password http://unused.invalid/")
    machine.succeed("agent-vault-access disable personal-dev")
    machine.succeed("python3 -c \"from pathlib import Path; p=Path('/etc/personal-password'); p.unlink(); p.write_text('rotated-password'); p.chmod(0o600)\"")
    exported = json.loads(machine.succeed("agent-vault-access export personal-dev"))
    assert exported == {"identity": "personal-dev", "password": "rotated-password"}, exported
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    assert machine.succeed(curl + " --proxy-user personal-dev:rotated-password -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    machine.succeed("agent-vault-access enable personal-dev")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    assert machine.succeed(curl + " --proxy-user personal-dev:personal-password -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    response = json.loads(machine.succeed(curl + " --fail --proxy-user personal-dev:rotated-password http://unused.invalid/"))
    assert response["auth"] == [personal], response
    machine.succeed(curl + " --fail --proxy-user personal-test:test-password http://unused.invalid/")
    journal = machine.succeed("journalctl -u agent-vault-shared-proxy.service --no-pager")
    assert "identity=personal-dev" in journal, journal
    for secret in ["personal-password", "rotated-password", "work-password", "personal-token", "work-token", guest_auth, personal.split()[1]]:
        assert secret not in journal, journal
    machine.fail("agent-vault-access disable missing")
    machine.fail("runuser -u operator -- agent-vault-access disable personal-dev")
    machine.fail(ssh + " " + destination + " true")
    machine.fail(ssh + " -W 127.0.0.1:14321 " + destination + " </dev/null")
    status, output = machine.execute(ssh + " -o ExitOnForwardFailure=yes -R 127.0.0.1:0:127.0.0.1:14321 " + destination + " true 2>&1")
    assert status != 0 and "remote port forwarding failed" in output, output
    machine.succeed("runuser -u agent-vault-tunnel -- python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('/var/lib/voom-agent-vault-public/unrelated.sock')\"")
    machine.succeed(ssh + " -o ControlPath=/tmp/proxy-control -O forward -L 127.0.0.1:13129:/var/lib/voom-agent-vault-public/unrelated.sock " + destination)
    machine.fail("curl --noproxy \"\" --silent --show-error --fail -x http://127.0.0.1:13129 http://unused.invalid/")
    machine.fail("runuser -u agent-vault-tunnel -- test -r /etc/personal-token")
    machine.fail("runuser -u agent-vault-tunnel -- test -r /run/agent-vault-shared-proxy/access.map")
    machine.fail("runuser -u nobody -- python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('/run/agent-vault-shared-proxy/proxy.sock')\"")
    machine.succeed("/run/booted-system/specialisation/no-access/bin/switch-to-configuration test")
    machine.wait_until_succeeds("test -S /run/agent-vault-shared-proxy/proxy.sock")
    assert machine.succeed(curl + " --proxy-user work:work-password -o /dev/null -w '%{http_code}' http://unused.invalid/") == "407"
    machine.succeed(ssh + " -o ControlPath=/tmp/proxy-control -O exit " + destination)
  '';
}
