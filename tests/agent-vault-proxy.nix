{ pkgs }:
let
  proxy = pkgs.callPackage ../packages/agent-vault-proxy.nix {
    credentialFile = "./credential.json";
    environment = {
      HTTPS_PROXY = "http://127.0.0.1:19312";
      NO_PROXY = "localhost,.example.test";
      SSL_CERT_FILE = "./ca bundle.pem";
    };
  };
  egress = pkgs.callPackage ../packages/proxy.nix {
    proxyCommand = [
      (pkgs.lib.getExe proxy)
      "run"
    ];
  };
in
pkgs.runCommand "agent-vault-proxy-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.openssl
      pkgs.fish
    ];
  }
  ''
    openssl req -x509 -newkey ed25519 -noenc -days 1 \
      -subj /CN=api.github.com -addext subjectAltName=DNS:api.github.com \
      -keyout key.pem -out 'ca bundle.pem'
    python3 - <<'PY'
    import http.server
    import base64
    import json
    import ssl
    import subprocess
    import threading
    from pathlib import Path
    from urllib.parse import quote

    command = "${pkgs.lib.getExe proxy}"
    egress = "${pkgs.lib.getExe egress}"
    python = "${pkgs.python3}/bin/python3"
    inspect = [python, "-c", "import json, os, sys; print(json.dumps([dict(os.environ), sys.argv[1:]]))"]
    stale = {
        "HTTPS_PROXY": "http://old-host:1", "ALL_PROXY": "socks5://old-host:2",
        "NO_PROXY": "*", "SSL_CERT_FILE": "/old-ca", "GH_TOKEN": "__github_other_pat__",
    }
    password = "a:p/ss@ ?'\\word"
    login = json.dumps({"identity": "personal-dev", "password": password})
    result = subprocess.run([command, "login"], input=login, env={}, text=True, capture_output=True, check=True)
    assert password not in result.stdout + result.stderr
    assert Path("credential.json").stat().st_mode & 0o777 == 0o600
    authenticated = "http://personal-dev:" + quote(password, safe="") + "@127.0.0.1:19312"

    result = subprocess.run(
        [egress, "run", "--", *inspect, "two words", ""],
        env=stale, text=True, capture_output=True, check=True,
    )
    environment, arguments = json.loads(result.stdout)
    assert environment["HTTPS_PROXY"] == authenticated, environment
    assert environment["NO_PROXY"] == "localhost,.example.test", environment
    assert environment["GH_TOKEN"] == "__github_other_pat__", environment
    assert "ALL_PROXY" not in environment, environment
    assert arguments == ["two words", ""], arguments

    result = subprocess.run(
        [command, "run", *inspect], env={}, text=True, capture_output=True, check=True,
    )
    assert json.loads(result.stdout)[0]["GH_TOKEN"] == "__github_token__"

    for token in ["__github_token__", "__github_other_pat__"]:
        result = subprocess.run(
            [egress, "bypass", "--", *inspect],
            env={**stale, "GH_TOKEN": token}, text=True, capture_output=True, check=True,
        )
        environment = json.loads(result.stdout)[0]
        assert not any(key in environment for key in stale if key != "GH_TOKEN"), environment
        assert environment.get("GH_TOKEN") == (None if token == "__github_token__" else token)

    for action in ["run", "bypass"]:
        result = subprocess.run([egress, action, python, "-c", "raise SystemExit(37)"], env={})
        assert result.returncode == 37, result

    for flags, executable, extension in [([], "${pkgs.bash}/bin/bash", "sh"), (["--fish"], "${pkgs.fish}/bin/fish", "fish")]:
        exports = subprocess.run([command, "env", *flags], env=stale, text=True, capture_output=True, check=True)
        Path("environment." + extension).write_text(exports.stdout)
        result = subprocess.run(
            [executable, "--no-config" if extension == "fish" else "--noprofile", "-c",
             "source ./environment." + extension + "; " + python + " -c 'import json, os; print(json.dumps(dict(os.environ)))'"],
            env={**stale, "all_proxy": "socks5://old-host:3"}, text=True, capture_output=True, check=True,
        )
        environment = json.loads(result.stdout)
        assert environment["HTTPS_PROXY"] == authenticated, result
        assert "ALL_PROXY" not in environment and "all_proxy" not in environment, result

    result = subprocess.run([command, "login"], input='{"identity":"../bad","password":"x"}', env={}, text=True, capture_output=True)
    assert result.returncode != 0 and json.loads(Path("credential.json").read_text())["password"] == password
    Path("credential.json").chmod(0o644)
    result = subprocess.run([command, "run", *inspect], env={}, text=True, capture_output=True)
    assert result.returncode != 0 and "private file" in result.stderr
    Path("credential.json").chmod(0o600)

    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain("ca bundle.pem", "key.pem")
    requests = []
    status = 200

    class API(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

    class Proxy(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_CONNECT(self):
            assert self.path == "api.github.com:443", self.path
            expected = "Basic " + base64.b64encode(("personal-dev:" + password).encode()).decode()
            assert self.headers.get("Proxy-Authorization") == expected, self.headers
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            with tls.wrap_socket(self.connection, server_side=True) as connection:
                API(connection, self.client_address, self.server)

    with http.server.HTTPServer(("127.0.0.1", 19312), Proxy) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run([command, "check"], env=stale, text=True, capture_output=True, timeout=10)
            assert result.returncode == 0, result
            assert "GitHub API: HTTP 200" in result.stdout, result
            assert password not in result.stdout + result.stderr and quote(password, safe="") not in result.stdout
            assert requests == [("/user", "Bearer __github_token__")], requests
            for status in [302, 401]:
                result = subprocess.run([command, "check"], env=stale, text=True, capture_output=True, timeout=10)
                assert result.returncode != 0, result
                assert f"GitHub API: HTTP {status}" in result.stdout, result
        finally:
            server.shutdown()
    Path("credential.json").unlink()
    result = subprocess.run([command, "env", "--fish", "--if-present"], env={}, text=True, capture_output=True, check=True)
    assert not result.stdout and not result.stderr, result
    result = subprocess.run([command, "check"], env={}, text=True, capture_output=True)
    assert result.returncode != 0 and "no proxy credential" in result.stderr
    subprocess.run([egress, "bypass", python, "-c", "pass"], env={}, check=True)
    PY
    touch "$out"
  ''
