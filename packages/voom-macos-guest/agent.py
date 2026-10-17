import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone


CONTROL = Path("/var/run/voom")
TAG = "voom-control"


def mounted_filesystems():
    result = subprocess.run(["/sbin/mount"], check=True, capture_output=True, text=True, timeout=10)
    mounts = {}
    for line in result.stdout.splitlines():
        source, separator, rest = line.partition(" on ")
        target, options_start, options = rest.rpartition(" (")
        if separator and options_start and options.endswith(")"):
            mounts[os.path.realpath(target)] = (source, options[:-1].split(", "))
    return mounts


def mount_share(tag, target, readonly, mounts):
    target = Path(target)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag) or not target.is_absolute():
        raise ValueError("invalid share tag or mount path")
    resolved = target.resolve()
    control = CONTROL.resolve()
    overlaps_control = resolved.is_relative_to(control) or control.is_relative_to(resolved)
    if resolved == Path("/") or (tag != TAG and overlaps_control):
        raise ValueError(f"share overlaps reserved storage: {target}")
    current = mounts.get(str(resolved))
    if current is not None:
        source, options = current
        if source != tag or "virtiofs" not in options or (readonly and "read-only" not in options):
            raise RuntimeError(f"conflicting mount at {target}: {source}")
        return
    target.mkdir(parents=True, exist_ok=True)
    command = ["/sbin/mount_virtiofs"]
    if readonly:
        command += ["-o", "ro"]
    subprocess.run([*command, tag, str(target)], check=True, capture_output=True, text=True, timeout=15)
    mounts[str(resolved)] = (tag, ["virtiofs", "read-only"] if readonly else ["virtiofs"])


def parse_listeners(data):
    listeners = []
    process = {}
    seen = set()
    for field in data.split(b"\0"):
        field = field.lstrip(b"\n")
        if not field:
            continue
        kind, value = field[:1], field[1:].decode("utf-8", errors="replace")
        if kind == b"p":
            process = {"pid": int(value)}
        elif kind == b"c":
            process["process"] = value
        elif kind == b"n":
            address, separator, port_text = value.rpartition(":")
            if not separator:
                raise ValueError(f"invalid lsof listener: {value}")
            address = address.removeprefix("[").removesuffix("]").split("%", 1)[0]
            port = int(port_text)
            if address != "*":
                ipaddress.ip_address(address)
            if not 1 <= port <= 65535:
                raise ValueError(f"invalid listener port: {port}")
            identity = (address, port, process.get("pid"))
            if identity not in seen:
                seen.add(identity)
                listeners.append({"proto": "tcp", "addr": address, "port": port, **process})
    return listeners


def report_ports():
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F0pcn"],
        capture_output=True, timeout=15,
    )
    # lsof exits 1 with no output when no sockets match the selection.
    if result.returncode != 0 and not (result.returncode == 1 and not result.stdout and not result.stderr):
        raise RuntimeError(f"lsof failed ({result.returncode}): {result.stderr.decode(errors='replace').strip()}")
    if result.stderr:
        raise RuntimeError(f"lsof reported incomplete results: {result.stderr.decode(errors='replace').strip()}")
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "listeners": parse_listeners(result.stdout),
    }


def publish_report(report):
    temporary = CONTROL / f".ports.json.{os.getpid()}"
    try:
        with temporary.open("w") as stream:
            json.dump(report, stream)
            stream.write("\n")
        temporary.chmod(0o644)
        temporary.replace(CONTROL / "ports.json")
    finally:
        temporary.unlink(missing_ok=True)


def run():
    failures = {}

    def attempt(name, action):
        try:
            action()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            message = str(error)
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                message += ": " + error.stderr.strip()
            if failures.get(name) != message:
                print(f"{name}: {message}", file=sys.stderr, flush=True)
                failures[name] = message
            return False
        if name in failures:
            print(f"{name}: recovered", file=sys.stderr, flush=True)
            del failures[name]
        return True

    while True:
        def synchronize():
            mounts = mounted_filesystems()
            mount_share(TAG, CONTROL, False, mounts)
            manifest = json.loads((CONTROL / "mounts.json").read_text())
            if not isinstance(manifest, list):
                raise ValueError("mounts.json must contain a list")
            for share in manifest:
                if not isinstance(share, dict) or set(share) != {"tag", "guestPath", "readonly"}:
                    raise ValueError("invalid share declaration")
                tag, target, readonly = share["tag"], share["guestPath"], share["readonly"]
                if not isinstance(tag, str) or not isinstance(target, str) or type(readonly) is not bool or tag == TAG:
                    raise ValueError("invalid share declaration")
                attempt(f"share {tag}", lambda: mount_share(tag, target, readonly, mounts))
            attempt("port report", lambda: publish_report(report_ports()))

        attempt("control share", synchronize)
        time.sleep(2)


if __name__ == "__main__":
    run()
