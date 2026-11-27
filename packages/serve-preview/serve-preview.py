import argparse
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener


def vm_name():
    status = json.loads(subprocess.check_output(
        ["tailscale", "status", "--json"], text=True,
    ))
    peer = status.get("Self") or {}
    name = peer.get("DNSName", "").partition(".")[0].lower()
    if status.get("BackendState") != "Running" or not re.fullmatch(
        r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", name,
    ):
        raise ValueError("The VM has no active Tailscale DNS name")
    return name


def ephemeral_ports():
    if sys.platform == "darwin":
        values = subprocess.check_output([
            "/usr/sbin/sysctl", "-n",
            "net.inet.ip.portrange.first", "net.inet.ip.portrange.last",
        ], text=True)
    else:
        values = Path("/proc/sys/net/ipv4/ip_local_port_range").read_text()
    first, last = map(int, values.split())
    return range(first, last + 1)


def open_preview(port, block):
    try:
        subprocess.run(
            ["ladybird", "--split", "right", f"http://127.0.0.1:{port}"],
            env=os.environ | {"REX_BLOCK": block},
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"serve-preview: could not open Ladybird: {error}",
              file=sys.stderr, flush=True)


def wait_for_published_url(url):
    opener = build_opener(ProxyHandler({}))
    request = Request(url, method="HEAD")
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            with opener.open(request, timeout=1):
                return
        except (URLError, TimeoutError):
            time.sleep(0.25)
    raise ValueError("the HTTPS route is not ready yet")


def open_default_browser(url, client_id):
    try:
        if not client_id:
            raise ValueError("no Rex app initiated this action")
        bin_dir = os.environ.get("REX_BIN_DIR")
        rex = [str(Path(bin_dir) / "rex") if bin_dir else "rex",
               "--autostart=false"]
        inspection = json.loads(subprocess.check_output(
            rex + ["client", "inspect", client_id, "--json"], text=True,
        ))
        if not any(action["name"] == "client.url.open"
                   for action in inspection.get("actions") or []):
            raise ValueError("the Rex client lacks client.url.open")
        if url.startswith("https://"):
            wait_for_published_url(url)
        elif inspection["client"]["principal"]["kind"] != "peer":
            raise ValueError("the remote Rex client needs a published URL")
        subprocess.run(
            rex + ["-C", client_id, "do", "client.url.open", f"url={url}"],
            check=True,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"serve-preview: could not open the default browser: {error}",
              file=sys.stderr, flush=True)


def serve(directory, port, preview_url, args):
    listening = False
    address_in_use = False
    with subprocess.Popen(
        ["serve", str(port), str(directory)],
        # Miniserve's startup banner is the readiness signal for the preview.
        env=os.environ | {"MINISERVE_QUIET": "false"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    ) as server:
        for line in server.stdout:
            print(line, end="", flush=True)
            if not listening and line.startswith("Bound to "):
                listening = True
                print(f"Preview: {preview_url}", flush=True)
                if args.view_from is not None:
                    open_preview(port, args.view_from)
                elif args.open_in_client is not None:
                    open_default_browser(preview_url, args.open_in_client)
            elif "caused by: Address already in use" in line:
                address_in_use = True
        status = server.wait()
    return status, not listening and address_in_use


def main():
    parser = argparse.ArgumentParser(description="Serve a directory preview")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--port", type=int)
    viewer = parser.add_mutually_exclusive_group()
    viewer.add_argument("--view-from", metavar="BLOCK")
    viewer.add_argument("--open-in-client", metavar="CLIENT")
    args = parser.parse_args()
    directory = args.directory.expanduser().absolute()
    if not directory.is_dir():
        parser.error(f"not a directory: {directory}")

    try:
        domain = os.environ.get("SERVE_PREVIEW_DOMAIN")
        unpublished = set(ephemeral_ports()) | {22, 7780} if domain else set()
        if args.port is None:
            ports = [port for port in range(20000, 30000)
                     if port not in unpublished]
            random.shuffle(ports)
        else:
            if not 1 <= args.port <= 65535:
                parser.error("port must be between 1 and 65535")
            if args.port in unpublished:
                parser.error(f"loopback port {args.port} is skipped by Caddy")
            ports = [args.port]

        hostname = vm_name() if domain else None
        for port in ports:
            url = (f"https://{hostname}-{port}.{domain}" if hostname else
                   f"http://localhost:{port}")
            status, address_in_use = serve(directory, port, url, args)
            if args.port is not None or not address_in_use:
                return status if status >= 0 else 128 - status
        print("serve-preview: no free port in 20000–29999", file=sys.stderr)
        return 1
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"serve-preview: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
