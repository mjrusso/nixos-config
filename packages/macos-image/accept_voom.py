import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid


VM = "acceptance-vm"
IMAGE = "acceptance-image"
HELPERS = ("vfkit", "gvproxy", "voom-macos-identity")


def fingerprint_bundle(bundle):
    files = {}
    for name in ("image.json", "restore.json", "toolchain.json", "HardwareModel", "MachineIdentifier", "AuxiliaryStorage", "disk.raw"):
        path = bundle / name
        info = path.stat()
        files[name] = {"size": info.st_size, "mtimeNs": info.st_mtime_ns}
        if name != "disk.raw":
            with path.open("rb") as stream:
                files[name]["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
    return files


def acceptance_environment(root):
    env = {name: value for name, value in os.environ.items() if not name.startswith("VOOM_")}
    for name, directory in (("CONFIG", "config"), ("STATE", "state"), ("CACHE", "cache"), ("RUNTIME", "run")):
        env[f"VOOM_{name}_DIR"] = str(root / directory)
    return env


class Acceptance:
    def __init__(self, voom, bundle, identity, root, timeout):
        self.voom = voom
        self.bundle = bundle
        self.identity = identity
        self.root = root
        self.timeout = timeout
        self.env = acceptance_environment(root)
        self.evidence = root / "evidence"
        self.evidence.mkdir()
        self.sequence = 0
        self.token = uuid.uuid4().hex

    def save(self, name, data):
        (self.evidence / name).write_text(json.dumps(data, indent=2) + "\n")

    def command(self, *args, executable=None, check=True, timeout=None):
        self.sequence += 1
        stem = self.evidence / f"{self.sequence:03d}-{args[0]}"
        command = [str(executable or self.voom), *args]
        stem.with_suffix(".command.json").write_text(json.dumps(command) + "\n")
        with stem.with_suffix(".stdout").open("w") as stdout, stem.with_suffix(".stderr").open("w") as stderr:
            process = subprocess.Popen(command, env=self.env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                process.wait(timeout=timeout or self.timeout)
            except BaseException:
                # Terminate the command's SSH children too; detached Voom runtime helpers are cleaned separately.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
        result = subprocess.CompletedProcess(command, process.returncode, stem.with_suffix(".stdout").read_text(), stem.with_suffix(".stderr").read_text())
        if check and result.returncode:
            raise RuntimeError(f"{shlex.join(command)} failed ({result.returncode}): {result.stderr.strip()}; evidence: {stem}")
        return result

    def json(self, *args, **kwargs):
        return json.loads(self.command(*args, "--output", "json", **kwargs).stdout)

    def ssh(self, script):
        return self.command("ssh", VM, "--", "/bin/sh -c " + shlex.quote("set -eu\n" + script), timeout=min(90, self.timeout)).stdout

    def check_helpers(self):
        paths = self.json("debug", "helpers")
        if Path(paths["voom"]).resolve() != self.voom:
            raise RuntimeError("Voom reported a different executable from the selected package")
        evidence = {}
        for name in HELPERS:
            bundled = self.voom.parent / name
            selected = Path(paths[name])
            if not bundled.is_file() or not os.access(bundled, os.X_OK) or selected.resolve() != bundled.resolve():
                raise RuntimeError(f"{name} is not resolved from the selected Voom package: {selected}")
            with bundled.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            evidence[name] = {"path": str(selected), "resolvedPath": str(selected.resolve()), "sha256": digest}
            if name != "voom-macos-identity":
                flag = "--capabilities" if name == "vfkit" else "-capabilities"
                result = self.command(flag, executable=bundled, timeout=15)
                capabilities = json.loads(result.stdout)
                required = ("gui-lifecycle-v1", "virtiofs-readonly-v1") if name == "vfkit" else ("guest-isolation-v1",)
                if any(capabilities.get(capability) != 1 for capability in required):
                    raise RuntimeError(f"bundled {name} lacks required capabilities: {capabilities}")
                evidence[name]["capabilities"] = capabilities
                version_flag = "--version" if name == "vfkit" else "-version"
                version = self.command(version_flag, executable=bundled, timeout=15)
                evidence[name]["version"] = version.stdout.strip()
            else:
                self.command("--self-test", executable=bundled, timeout=15)
                evidence[name]["selfTest"] = "passed"
        self.save("helpers.json", evidence)
        self.command("version")
        paths = self.json("debug", "paths")
        for key in ("config", "state", "cache", "runtime"):
            expected = self.env[f"VOOM_{key.upper()}_DIR"]
            if Path(paths[key]).resolve() != Path(expected).resolve():
                raise RuntimeError(f"Voom did not honor isolated {key} directory")
        self.save("environment.json", {name: value for name, value in self.env.items() if name.startswith("VOOM_")})
        checks = self.json("doctor")
        self.save("doctor.json", checks)
        failures = [check for check in checks if not check["ok"] and check["severity"] == "fatal"]
        if failures:
            raise RuntimeError(f"Voom doctor failed: {failures}")

    def wait_for(self, description, check):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            result = check()
            if result:
                return result
            time.sleep(2)
        raise TimeoutError(f"Timed out waiting for {description}; see {self.evidence}")

    def verify_guest(self, phase):
        report = None

        def probe():
            nonlocal report
            limit = min(30, self.timeout)
            result = self.command("guest", "verify", VM, "--timeout", f"{limit}s", "--output", "json", check=False, timeout=limit + 5)
            report = json.loads(result.stdout)
            self.save(f"{phase}-guest.json", report)
            for check in report.get("checks", []):
                if check["name"] in ("platform-storage", "driver-running") and not check["ok"]:
                    raise RuntimeError(f"VM cannot become ready: {check}")
            return report if result.returncode == 0 else None

        try:
            self.wait_for("MacOS guest verification", probe)
        except TimeoutError as error:
            failures = [check["name"] for check in report.get("checks", []) if not check["ok"]] if report else []
            raise TimeoutError(f"MacOS guest verification timed out; failing checks: {', '.join(failures) or 'no report'}; see {self.evidence}") from error
        return self.json("info", VM)

    def verify_shares(self):
        self.ssh(f'''for attempt in $(seq 1 60); do
    if test -f /Volumes/voom-accept-rw/from-host && test -f /Volumes/voom-accept-ro/from-host; then break; fi
    sleep 1
done
test "$(cat /Volumes/voom-accept-rw/from-host)" = {self.token}
test "$(cat /Volumes/voom-accept-ro/from-host)" = {self.token}
printf '%s\\n' {self.token} > /Volumes/voom-accept-rw/from-guest
if sudo -n /usr/bin/touch /Volumes/voom-accept-ro/forbidden-write; then exit 1; fi
''')
        if (self.root / "rw/from-guest").read_text().strip() != self.token or (self.root / "ro/forbidden-write").exists():
            raise RuntimeError("Shared-file round trip or read-only enforcement failed")

    def verify_forwarding(self, phase):
        code = '''import functools, http.server, json, os
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="/Volumes/voom-accept-rw")
server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), handler)
pid = os.fork()
if pid:
    print(json.dumps({"port": server.server_port, "pid": pid}), flush=True)
    os._exit(0)
os.setsid()
with open(os.devnull, "r+b", buffering=0) as null:
    for descriptor in (0, 1, 2):
        os.dup2(null.fileno(), descriptor)
server.serve_forever()
'''
        server = json.loads(self.ssh("/run/current-system/sw/bin/python3 -c " + shlex.quote(code)))
        port, pid = server["port"], server["pid"]

        def installed():
            rows = self.json("forward", "list", VM)
            return next((row for row in rows if row["kind"] == "auto" and row["guestPort"] == port and row["installed"]), None)

        row = self.wait_for("automatic TCP forwarding", installed)
        self.save(f"{phase}-forward.json", row)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://127.0.0.1:{row['hostPort']}/from-host", timeout=10) as response:
            if response.read().decode().strip() != self.token:
                raise RuntimeError("Forwarded HTTP response did not match the shared file")
        self.ssh(f"/bin/kill -TERM {int(pid)}")
        self.wait_for("automatic forward removal", lambda: not any(row["kind"] == "auto" and row["guestPort"] == port for row in self.json("forward", "list", VM)))

    def run(self):
        print(f"Acceptance evidence: {self.evidence}", flush=True)
        self.check_helpers()
        before = fingerprint_bundle(self.bundle)
        self.save("source-before.json", before)
        try:
            manifest = json.loads((self.bundle / "image.json").read_text())
            capabilities = manifest.get("capabilities", {})
            if not all(capabilities.get(name) is True for name in ("controlShare", "guestShareMount", "guestPortReport")):
                raise RuntimeError("Re-bake this bundle with Darwin guest services before running acceptance")
            print("Importing a disposable image and creating a VM...", flush=True)
            self.command("image", "import", IMAGE, str(self.bundle), "--ssh-identity", str(self.identity))
            self.save("image.json", self.json("image", "inspect", IMAGE))
            self.command("create", VM, "--image", IMAGE)
            for name in ("rw", "ro"):
                directory = self.root / name
                directory.mkdir()
                (directory / "from-host").write_text(self.token + "\n")
                flags = ("--readonly",) if name == "ro" else ()
                self.command("share", "add", VM, "accept-" + name, str(directory), "/Volumes/voom-accept-" + name, *flags)
            self.command("forward", "auto", "enable", VM)
            self.command("start", VM)
            first = self.verify_guest("first")
            self.save("first-info.json", first)
            self.verify_shares()
            self.verify_forwarding("first")
            self.ssh(f"printf '%s\\n' {self.token} > \"$HOME/voom-accept-marker\"")
            print("Restarting and checking persistence, shares, and forwarding...", flush=True)
            self.command("stop", VM)
            self.command("start", VM)
            restarted = self.verify_guest("restart")
            self.save("restart-info.json", restarted)
            if first["vm"]["macos"]["identitySha256"] != restarted["vm"]["macos"]["identitySha256"]:
                raise RuntimeError("Apple identity changed across restart")
            self.ssh(f'test "$(cat "$HOME/voom-accept-marker")" = {self.token}')
            self.verify_shares()
            self.verify_forwarding("restart")
        finally:
            after = fingerprint_bundle(self.bundle)
            self.save("source-after.json", after)
            if before != after:
                raise RuntimeError("The source bundle changed during acceptance")

    def cleanup(self):
        rows = self.json("list")
        if any(row["name"] == VM for row in rows):
            if any(row["name"] == VM and row.get("status") == "running" for row in rows):
                script = '''set +e
printf '\\n--- Guest service ---\\n'
sudo -n /bin/launchctl print system/org.voom.guest-services
printf '\\n--- Guest service log ---\\n'
sudo -n /usr/bin/tail -n 100 /var/log/voom-guest-services.log
printf '\\n--- Mounted filesystems ---\\n'
/sbin/mount
printf '\\n--- Guest service plist ---\\n'
/bin/cat /Library/LaunchDaemons/org.voom.guest-services.plist
'''
                try:
                    self.command("ssh", VM, "--", "/bin/sh -c " + shlex.quote(script), check=False, timeout=min(30, self.timeout))
                except Exception as error:
                    self.save("guest-diagnostics-error.json", {"error": str(error)})
            for kind in ("vfkit", "gvproxy", "auto-forward", "runtime-watch"):
                self.command("logs", VM, "--kind", kind, check=False)
            self.command("stop", VM)
            self.command("remove", VM, "--force")
        images = self.json("image", "list")
        if any(image["name"] == IMAGE for image in images):
            self.command("image", "remove", IMAGE, "--force")
        if self.json("list") or self.json("image", "list"):
            raise RuntimeError("Acceptance objects remain after cleanup")


def interrupt(signum, frame):
    raise KeyboardInterrupt(f"Received signal {signum}")


def execute(acceptance):
    failure = None
    try:
        acceptance.run()
    except (Exception, KeyboardInterrupt) as error:
        failure = str(error) or "Interrupted"
    try:
        acceptance.cleanup()
    except (Exception, KeyboardInterrupt) as error:
        failure = f"{failure + '; ' if failure else ''}cleanup failed: {error}. Retained state: {acceptance.root}"
    acceptance.save("result.json", {"passed": failure is None, "error": failure})
    if failure:
        print(f"Acceptance failed: {failure}\nEvidence: {acceptance.evidence}", file=sys.stderr)
        return 1
    print(f"Acceptance passed. Disposable objects removed; evidence: {acceptance.evidence}")
    return 0


def main():
    parser = argparse.ArgumentParser(prog="verify-macos-voom", description="Test a baked MacOS bundle through a Voom package and its bundled helpers.")
    parser.add_argument("--voom", type=Path, required=True, help="Voom executable from the package to test")
    parser.add_argument("--bundle", type=Path, default=Path("~/vms/golden-aarch64-darwin"))
    parser.add_argument("--identity", type=Path, default=Path("~/.ssh/id_ed25519"))
    parser.add_argument("--work-dir", type=Path, help="new evidence/state directory (default: a new directory under /tmp)")
    parser.add_argument("--timeout", type=int, default=600, help="timeout per command/readiness stage in seconds")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("acceptance requires an Apple Silicon Mac with a graphical login session")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    voom, bundle, identity = (path.expanduser().resolve() for path in (args.voom, args.bundle, args.identity))
    if not voom.is_file() or not os.access(voom, os.X_OK) or not bundle.is_dir() or not identity.is_file():
        parser.error("--voom, --bundle, and --identity must point to existing executable/bundle/key paths")
    root = args.work_dir.expanduser().resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="voom-accept-", dir="/tmp")).resolve()
    if "," in str(root):
        parser.error("--work-dir cannot contain vfkit's comma option delimiter")
    if root.is_relative_to(bundle):
        parser.error("--work-dir must be outside the source bundle")
    if len(os.fsencode(root / "run" / ("x" * 32) / "vfkit.sock")) >= 104:
        parser.error("--work-dir is too long for MacOS Unix sockets; choose a short path under /tmp")
    if args.work_dir:
        try:
            root.mkdir(mode=0o700)
        except OSError as error:
            parser.error(f"--work-dir must be a new directory: {error}")
    acceptance = Acceptance(voom, bundle, identity, root, args.timeout)
    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        return execute(acceptance)
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    sys.exit(main())
