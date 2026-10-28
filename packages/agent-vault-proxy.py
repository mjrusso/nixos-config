import argparse
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlsplit, urlunsplit


def credential(value):
    if not isinstance(value, dict):
        raise ValueError("credential must contain identity and password")
    identity, password = value.get("identity"), value.get("password")
    if not isinstance(identity, str) or not re.fullmatch(r"[a-zA-Z0-9_-]+", identity):
        raise ValueError("credential has an invalid identity name")
    if not isinstance(password, str) or not password or any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise ValueError("credential must have a nonempty password without control characters")
    return {"identity": identity, "password": password}


def environment(config, path):
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError(f"{path}: credential must be a private file (mode 0600)")
    value = credential(json.loads(path.read_text()))
    url = urlsplit(config["url"])
    authority = f"{quote(value['identity'], safe='')}:{quote(value['password'], safe='')}@{url.netloc}"
    authenticated = urlunsplit(url._replace(netloc=authority))
    result = dict(config["environment"])
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
        result[name] = authenticated
    result["GH_TOKEN"] = os.environ.get("GH_TOKEN") or "__github_token__"
    return result


def main():
    with open(sys.argv[1]) as stream:
        config = json.load(stream)
    parser = argparse.ArgumentParser(prog="agent-vault-proxy")
    commands = parser.add_subparsers(dest="action", required=True)
    for action in ("run", "direct"):
        command = commands.add_parser(action)
        command.add_argument("command", nargs=argparse.REMAINDER)
    commands.add_parser("check", help="verify the proxy and default GitHub API credential")
    commands.add_parser("login", help="install an exported credential from stdin")
    shell = commands.add_parser("env", help="emit shell assignments containing the proxy credential")
    shell.add_argument("--fish", action="store_true")
    shell.add_argument("--if-present", action="store_true")
    args = parser.parse_args(sys.argv[2:])
    if args.action in ("run", "direct"):
        if args.command[:1] == ["--"]:
            args.command.pop(0)
        if not args.command:
            parser.error(f"{args.action} requires a command")
        if args.action == "direct":
            os.execv(config["direct"], [config["direct"], "--", *args.command])
    path = Path(config["credentialFile"]).expanduser()
    if args.action == "login":
        value = credential(json.load(sys.stdin))
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".credential-")
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream)
                stream.write("\n")
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)
        print(f"Installed {value['identity']} at {path}; open a new shell or use run/check")
        return 0
    try:
        values = environment(config, path)
    except FileNotFoundError:
        if args.action == "env" and args.if_present:
            return 0
        raise ValueError(f"{path}: no proxy credential; install one with agent-vault-proxy login")
    if args.action == "env":
        print("set -e ALL_PROXY; set -e all_proxy;" if args.fish else "unset ALL_PROXY all_proxy")
        for name, value in sorted(values.items()):
            if args.fish:
                escaped = value.replace("\\", "\\\\").replace("'", "\\'")
                print(f"set -gx {name} '{escaped}';")
            else:
                print(f"export {name}={shlex.quote(value)}")
        return 0
    child = dict(os.environ)
    child.pop("ALL_PROXY", None)
    child.pop("all_proxy", None)
    child.update(values)
    if args.action == "run":
        os.execvpe(args.command[0], args.command, child)
    print(f"Proxy: {config['url']}", flush=True)
    result = subprocess.run([
        config["curl"], "-q", "--silent", "--show-error", "--noproxy", "",
        "--cacert", values["SSL_CERT_FILE"], "--connect-timeout", "5", "--max-time", "20",
        "--header", "Authorization: Bearer __github_token__", "--output", "/dev/null",
        "--write-out", "%{http_code}", "https://api.github.com/user",
    ], env=child, text=True, stdout=subprocess.PIPE)
    print(f"GitHub API: HTTP {result.stdout}")
    return result.returncode or (0 if result.stdout == "200" else 1)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"agent-vault-proxy: {error}", file=sys.stderr)
        sys.exit(1)
