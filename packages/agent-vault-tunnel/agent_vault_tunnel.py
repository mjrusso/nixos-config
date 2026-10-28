import ipaddress
import json
import re
import signal
import subprocess
import sys


ANCHOR = "com.apple/agent-vault-tunnel"
REMOTE_SOCKET = "/run/agent-vault-shared-proxy/proxy.sock"


class GuardError(RuntimeError):
    pass


def pf(config, *args, input=None):
    result = subprocess.run(
        [config["pfctl"], *args], input=input, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2,
    )
    if result.returncode:
        raise GuardError(f"pfctl {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def rule(config):
    address = ipaddress.IPv4Address(config["listenAddress"])
    if address.is_loopback or address.is_unspecified:
        raise GuardError("listenAddress must be the Mac host's LAN IPv4 address")
    port = int(config["port"])
    if not 1024 <= port <= 65535:
        raise GuardError("the proxy port must be between 1024 and 65535")
    return f"block drop in quick on ! lo0 inet proto tcp from any to {address} port = {port}"


def verify(config, restriction):
    if not re.search(r"^Status: Enabled\b", pf(config, "-s", "info"), re.MULTILINE):
        raise GuardError("PF is disabled")
    root = pf(config, "-sr").splitlines()
    if 'anchor "com.apple/*" all' not in root:
        raise GuardError("the main PF ruleset does not evaluate com.apple/*")
    actual = pf(config, "-a", ANCHOR, "-sr").strip()
    if actual != restriction:
        raise GuardError("the proxy's PF restriction is missing or has changed")


def run(config):
    stopping = False

    def terminate(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    restriction = rule(config)
    if 'anchor "com.apple/*" all' not in pf(config, "-sr").splitlines():
        raise GuardError("load the standard /etc/pf.conf before starting the tunnel")
    pf(config, "-a", ANCHOR, "-f", "-", input=restriction + "\n")
    token = None
    process = None
    try:
        if not re.search(r"^Status: Enabled\b", pf(config, "-s", "info"), re.MULTILINE):
            enabled = subprocess.run(
                [config["pfctl"], "-E"], capture_output=True, text=True,
                timeout=2, check=True,
            )
            match = re.search(r"Token\s*:\s*(\d+)", enabled.stdout + enabled.stderr)
            if not match:
                raise GuardError("PF did not return a reference token")
            token = match[1]
        verify(config, restriction)
        command = [
            config["ssh"], "-F", "/dev/null", "-a", "-NT",
            "-i", config["identityFile"],
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={config['knownHostsFile']}",
            "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-L", f"{config['listenAddress']}:{config['port']}:{REMOTE_SOCKET}",
            f"agent-vault-tunnel@{config['host']}",
        ]
        if stopping:
            return 0
        # launchd cleans up remaining processes in the job's process group.
        process = subprocess.Popen(command)
        while not stopping:
            try:
                return process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                if not stopping:
                    verify(config, restriction)
        return 0
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if token is not None:
            pf(config, "-X", token)


def main():
    with open(sys.argv[1]) as stream:
        config = json.load(stream)
    try:
        return run(config)
    except (GuardError, OSError, subprocess.SubprocessError) as error:
        print(f"agent-vault-tunnel: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
