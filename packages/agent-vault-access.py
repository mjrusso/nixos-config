import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


UNIT = "agent-vault-shared-proxy.service"


def secret(path):
    value = Path(path).read_text().removesuffix("\n")
    if not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError(f"{path}: expected one nonempty line")
    return value


def serve(config):
    os.umask(0o077)
    disabled = Path(config["stateDirectory"]) / "disabled"
    entries = []
    for name, identity in sorted(config["identities"].items()):
        if (disabled / name).exists():
            continue
        credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
        password = secret(credentials / f"password-{name}")
        vault = identity["vault"]
        token = secret(credentials / f"vault-{vault}")
        client = base64.b64encode(f"{name}:{password}".encode()).decode()
        upstream = base64.b64encode(f"{token}:{vault}".encode()).decode()
        entries.append(f"{client} {name}|{upstream}\n")
    Path(config["mapFile"]).write_text("".join(entries))
    os.execv(config["haproxy"], [config["haproxy"], "-db", "-f", config["haproxyConfig"]])


def main():
    with open(sys.argv[1]) as stream:
        config = json.load(stream)
    parser = argparse.ArgumentParser(prog="agent-vault-access")
    commands = parser.add_subparsers(dest="action", required=True)
    status = commands.add_parser("status", help="show configured identities and disabled holds")
    status.add_argument("identity", nargs="?", choices=sorted(config["identities"]))
    for action in ("disable", "enable", "export"):
        command = commands.add_parser(action)
        command.add_argument("identity", choices=sorted(config["identities"]))
    commands.add_parser("_serve", help=argparse.SUPPRESS)
    args = parser.parse_args(sys.argv[2:])
    if args.action == "_serve":
        serve(config)
        return 0
    if os.geteuid() != 0:
        parser.error("run with sudo on the Linux host")
    state = Path(config["stateDirectory"])
    disabled = state / "disabled"
    if args.action == "status":
        names = [args.identity] if args.identity else sorted(config["identities"])
        for name in names:
            status = "disabled" if (disabled / name).exists() else "enabled"
            print(f"{name}\t{config['identities'][name]['vault']}\t{status}")
    elif args.action == "export":
        password = secret(config["identities"][args.identity]["passwordFile"])
        print(json.dumps({"identity": args.identity, "password": password}))
    else:
        with (state / "access.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker = disabled / args.identity
            if args.action == "disable":
                marker.touch()
            else:
                marker.unlink(missing_ok=True)
            subprocess.run([config["systemctl"], "restart", UNIT], check=True)
        print(f"{args.identity}: {args.action}d; shared connections were closed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"agent-vault-access: {error}", file=sys.stderr)
        sys.exit(1)
