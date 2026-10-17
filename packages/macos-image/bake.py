import argparse
import ctypes
import fcntl
import hashlib
import ipaddress
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from contextlib import ExitStack, contextmanager
from pathlib import Path

from host_fonts import discover_fonts, host_font_directories, install_fonts, stage_fonts

RESOURCES = Path(__file__).resolve().parent


def parse_recipe(recipe):
    for name in ("ipsw", "nix"):
        artifact = recipe[name]
        if urllib.parse.urlparse(artifact["url"]).scheme not in ("https", "file"):
            raise ValueError(f"{name}.url must use https:// or file://")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", artifact["sha256"]):
            raise ValueError(f"{name}.sha256 must be a 64-character SHA-256 checksum")
    for name, minimum in (("cpuCount", 2), ("memoryMiB", 4096), ("diskGiB", 64)):
        if type(recipe[name]) is not int or not minimum <= recipe[name] <= 1048576:
            raise ValueError(f"{name} must be an integer between {minimum} and 1048576")
    if not isinstance(recipe["target"], str) or not recipe["target"]:
        raise ValueError("target must name a darwinConfigurations output")
    if not re.fullmatch(r"27\.\d+(?:\.\d+)?", recipe["sdkVersion"]):
        raise ValueError("sdkVersion must select an exact macOS 27 SDK version")
    families = recipe.get("fontFamilies", [])
    if not isinstance(families, list) or any(not isinstance(family, str) or not family.strip() for family in families):
        raise ValueError("fontFamilies must be a list of nonempty font family names")
    return {**recipe, "fontFamilies": [family.strip() for family in families]}


def load_configuration(flake):
    if not (flake / "flake.lock").is_file():
        raise ValueError("The system configuration flake must have a flake.lock")
    metadata = json.loads(
        subprocess.check_output(
            ["nix", "flake", "metadata", "--json", "--no-update-lock-file", flake],
            text=True,
        )
    )
    for name, node in metadata["locks"]["nodes"].items():
        locked = node.get("locked", {})
        if locked.get("type") == "path" and (
            Path(locked["path"]).is_absolute() or "parent" not in node
        ):
            raise ValueError(
                f"Input {name!r} uses a host-local path that cannot be transferred to the guest. "
                "Use a remote locked input or a relative path input within its containing source tree."
            )
    try:
        configuration = subprocess.check_output(
            ["nix", "eval", "--json", "--no-update-lock-file", f"{metadata['path']}#macosImage"],
            text=True,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as error:
        raise ValueError(
            f"Cannot evaluate macosImage in {flake}.\n"
            "Define macosImage in your system configuration flake's outputs.\n"
            f"{error.stderr.strip()}"
        ) from error
    recipe = parse_recipe(json.loads(configuration))
    return metadata, recipe


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(artifact, cache, suffix=""):
    expected = artifact["sha256"].lower()
    destination = cache / (expected + suffix)
    legacy = cache / expected
    if suffix and not destination.exists() and legacy.exists():
        legacy.replace(destination)
    if destination.exists():
        print(f"Verifying cached download: {artifact['url']}", flush=True)
        if checksum(destination) == expected:
            print("Cached download verified", flush=True)
            return destination
        print("Cached checksum mismatch; downloading again", flush=True)
    print(f"Downloading {artifact['url']}", flush=True)
    descriptor, name = tempfile.mkstemp(prefix=expected + ".", suffix=".partial", dir=cache)
    os.close(descriptor)
    partial = Path(name)
    try:
        with (
            urllib.request.urlopen(artifact["url"], timeout=60) as response,
            partial.open("wb") as stream,
        ):
            total = int(response.headers.get("Content-Length") or 0)
            received = 0
            started = last_report = time.monotonic()
            if total > 0:
                print(f"Download size: {total / 2**30:.2f} GiB", flush=True)
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
                received += len(chunk)
                now = time.monotonic()
                if now - last_report >= 5:
                    rate = received / (now - started)
                    progress = f"{received / 2**20:.1f} MiB"
                    if total > 0:
                        progress += f" / {total / 2**20:.1f} MiB ({received / total:.1%})"
                    progress += f", {rate / 2**20:.1f} MiB/s"
                    if total > 0:
                        minutes, seconds = divmod(max(0, round((total - received) / rate)), 60)
                        progress += f", ETA {minutes}m {seconds:02d}s"
                    print(f"Downloaded {progress}", flush=True)
                    last_report = now
        print(f"Downloaded {received / 2**20:.1f} MiB. Verifying SHA-256...", flush=True)
        if checksum(partial) != expected:
            raise ValueError(f"SHA-256 mismatch for {artifact['url']}")
        partial.replace(destination)
        print("Download verified", flush=True)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def lease_address(contents, mac):
    def normalize(value):
        return ":".join(f"{int(part, 16):02x}" for part in value.split(":"))

    matches = []
    for block in re.findall(r"\{([^}]+)\}", contents):
        fields = dict(re.findall(r"^\s*([a-z_]+)=(\S+)", block, re.MULTILINE))
        hardware = fields.get("hw_address", "").removeprefix("1,")
        try:
            if normalize(hardware) == normalize(mac):
                matches.append(str(ipaddress.IPv4Address(fields["ip_address"])))
        except (ValueError, KeyError):
            continue
    return matches[-1] if matches else None


class Guest:
    def __init__(self, user, identity, temporary):
        self.user = user
        self.address = None
        self.options = [
            "-F",
            "/dev/null",
            "-oUserKnownHostsFile=" + json.dumps(str(temporary / "known_hosts")),
            "-oStrictHostKeyChecking=accept-new",
            "-oConnectTimeout=5",
            "-oServerAliveInterval=15",
            "-oServerAliveCountMax=4",
            "-oIdentitiesOnly=yes",
            "-i",
            str(identity),
        ]

    def ssh(self, command, password_env=None, **kwargs):
        auth = (
            ["-oBatchMode=yes"]
            if password_env is None
            else [
                "-oPubkeyAuthentication=no",
                "-oNumberOfPasswordPrompts=1",
                "-oPreferredAuthentications=password,keyboard-interactive",
            ]
        )
        return subprocess.run(
            [
                "ssh",
                *self.options,
                *auth,
                f"{self.user}@{self.address}",
                "/bin/sh -c " + shlex.quote(command),
            ],
            check=True,
            text=True,
            env=password_env,
            **kwargs,
        )

    def wait(self, process, mac, password_env=None, timeout=900):
        started = next_report = time.monotonic()
        deadline = started + timeout
        failure = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(
                    f"VM exited before SSH became ready (status {process.returncode})"
                )
            try:
                leases = Path("/var/db/dhcpd_leases").read_text()
            except FileNotFoundError:
                leases = ""
            self.address = lease_address(leases, mac)
            if self.address:
                try:
                    self.ssh(
                        "true",
                        password_env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        timeout=15,
                    )
                    print(f"SSH login ready at {self.address}", flush=True)
                    return
                except subprocess.CalledProcessError as error:
                    failure = error.stderr.strip().splitlines()[-1] if error.stderr else str(error)
                except subprocess.TimeoutExpired:
                    failure = "SSH command timed out"
            now = time.monotonic()
            if now >= next_report:
                elapsed = int(now - started)
                status = f"Waiting for SSH login at {self.address}" if self.address else "Waiting for a DHCP lease"
                print(f"{status} ({elapsed // 60}m {elapsed % 60}s elapsed)", flush=True)
                if self.address and failure:
                    print(f"Last SSH error: {failure}", flush=True)
                next_report = now + 15
            time.sleep(3)
        raise TimeoutError("Timed out waiting for the VM's DHCP lease and SSH login")

    def copy(self, source, destination):
        subprocess.check_call(
            [
                "scp",
                *self.options,
                "-oBatchMode=yes",
                source,
                f"{self.user}@{self.address}:{destination}",
            ],
        )

    def shutdown(self, process):
        self.ssh("sudo -n /sbin/shutdown -h now")
        process.wait(timeout=180)
        if process.returncode:
            raise RuntimeError(f"VM shutdown failed (status {process.returncode})")


def bootstrap_home(guest, timeout, log):
    guest.ssh(
        "/run/current-system/sw/bin/fish --login --command home-bootstrap",
        timeout=timeout,
        stdout=log,
        stderr=log,
    )
    repositories = {}
    for name, directory in (("emacs", ".emacs.d"), ("wingman", "git/github.com/mjrusso/wingman")):
        command = f'git -C "$HOME/{directory}" rev-parse --verify HEAD'
        result = guest.ssh(
            shlex.join(["/run/current-system/sw/bin/fish", "--login", "--command", command]),
            stdout=subprocess.PIPE,
            stderr=log,
            timeout=60,
        )
        revision = result.stdout.strip()
        if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", revision):
            raise ValueError(f"Invalid bootstrap Git revision for {name}: {revision!r}")
        repositories[name] = {"directory": directory, "revision": revision}
    return {"repositories": repositories}


def stop_process(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


@contextmanager
def locked_storage(bundle):
    with ExitStack() as locks:
        for name in ("AuxiliaryStorage", "disk.raw"):
            path = bundle / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"Expected a regular storage file: {path}")
            stream = locks.enter_context(path.open("r+b"))
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise BlockingIOError(error.errno, "VM storage is in use", str(path)) from error
        yield


def check_output(destination):
    if destination.is_symlink():
        raise ValueError(f"Output must not be a symlink: {destination}")
    if not destination.exists():
        return
    if not destination.is_dir():
        raise ValueError(f"Output must be a bundle directory: {destination}")
    manifest = destination / "image.json"
    image = json.loads(manifest.read_text())
    if not isinstance(image, dict) or image.get("system") != "aarch64-darwin" or image.get("format") != "macos-bundle":
        raise ValueError(f"Refusing to replace a directory without a macOS bundle manifest: {destination}")
    for name in ("disk.raw", "AuxiliaryStorage", "MachineIdentifier", "HardwareModel", "restore.json", "toolchain.json", "image.json"):
        path = destination / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular bundle file: {path}")


def publish_bundle(bundle, destination):
    check_output(destination)
    if not destination.exists():
        bundle.rename(destination)
        return
    with locked_storage(destination):
        rename_swap = 0x00000002  # Darwin RENAME_SWAP exchanges complete directories atomically.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(bundle), os.fsencode(destination), rename_swap) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(destination))
    # The old bundle now occupies the staging path and is removed with the build directory.


def wait_for_storage(bundle, timeout=120):
    next_report = time.monotonic()
    deadline = next_report + timeout
    while True:
        try:
            with locked_storage(bundle):
                pass
            return
        except BlockingIOError as error:
            path = Path(error.filename)
            now = time.monotonic()
            if now >= deadline:
                raise TimeoutError(f"Timed out waiting for VM storage lock: {path.name}") from None
            if now >= next_report:
                print(f"Waiting for VM storage to be released: {path.name}", flush=True)
                next_report = now + 5
            time.sleep(1)


def vfkit_arguments(bundle, image):
    return [
        "vfkit",
        "--cpus",
        str(image["cpuCount"]),
        "--memory",
        str(image["memoryMiB"]),
        "--bootloader",
        "macos,"
        + ",".join(
            [
                f"machineIdentifierPath={bundle / 'MachineIdentifier'}",
                f"hardwareModelPath={bundle / 'HardwareModel'}",
                f"auxImagePath={bundle / 'AuxiliaryStorage'}",
            ]
        ),
        "--device",
        f"virtio-blk,path={bundle / 'disk.raw'}",
        "--device",
        f"virtio-net,nat,mac={image['macAddress']}",
        "--device",
        "virtio-gpu,width=1280,height=800",
        "--device",
        "virtio-input,keyboard",
        "--device",
        "virtio-input,pointing",
        "--gui",
    ]


def bake(args, metadata, recipe):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("bake-macos requires an Apple Silicon Mac running macOS 27 or later")
    if int(platform.mac_ver()[0].split(".")[0]) < 27:
        raise ValueError("bake-macos requires macOS 27 or later")
    for command in ("ssh", "scp", "ssh-keygen", "vfkit"):
        if not shutil.which(command):
            raise ValueError(f"Missing required command: {command}")
    sdk = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True
    ).strip()
    if sdk != recipe["sdkVersion"]:
        raise ValueError(
            f"Selected SDK is {sdk}; recipe requires {recipe['sdkVersion']}. Set DEVELOPER_DIR to the matching Xcode installation."
        )
    identity = args.identity.expanduser().resolve()
    public_key = Path(str(identity) + ".pub").read_text().strip()
    if not identity.is_file() or not public_key or "\n" in public_key:
        raise ValueError("--identity requires a private key and a single-line .pub file")
    subprocess.check_call(
        ["ssh-keygen", "-l", "-f", str(identity) + ".pub"],
        stdout=subprocess.DEVNULL,
    )
    snapshot = Path(metadata["path"])
    target = "darwinConfigurations." + json.dumps(recipe["target"]) + ".config"
    user = json.loads(
        subprocess.check_output(
            [
                "nix",
                "eval",
                "--json",
                "--no-update-lock-file",
                f"{snapshot}#{target}.system.primaryUser",
            ],
            text=True,
        )
    )
    if not isinstance(user, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]*", user):
        raise ValueError("The target must set system.primaryUser to a macOS account name")
    output = args.output.expanduser()
    if output.is_symlink():
        raise ValueError(f"Output must not be a symlink: {output}")
    destination = output.resolve()
    check_output(destination)
    if "," in str(destination):
        raise ValueError("The output path cannot contain a comma (vfkit option delimiter)")
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache = args.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".bake-macos-", dir=destination.parent) as work:
        temporary = Path(work)
        bundle = temporary / "image"
        bundle.mkdir()
        families = args.font_family if args.font_family is not None else recipe["fontFamilies"]
        if args.no_host_fonts:
            families = []
        font_staging = temporary / "fonts"
        fonts = stage_fonts(host_font_directories(), families, font_staging)
        image = {key: recipe[key] for key in ("cpuCount", "memoryMiB", "diskGiB")}
        image.update(
            {
                "schemaVersion": 1,
                "system": "aarch64-darwin",
                "format": "macos-bundle",
                "user": user,
                "target": recipe["target"],
                "macAddress": "02:" + ":".join(f"{byte:02x}" for byte in secrets.token_bytes(5)),
                "source": metadata.get("locked", {}),
                "recipe": recipe,
                "hostFonts": {"requestedFamilies": families, "files": fonts},
                "capabilities": {
                    "controlShare": False,
                    "guestPortReport": False,
                    "guestShareMount": False,
                    "nixosSwitch": False,
                },
            }
        )
        (bundle / "image.json").write_text(json.dumps(image, indent=2) + "\n")
        native = temporary / "macos-image-native"
        print("Compiling the native installer with the selected Apple SDK...", flush=True)
        subprocess.check_call(
            [
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "swiftc",
                "-parse-as-library",
                "-swift-version",
                "6",
                "-target",
                "arm64-apple-macos27.0",
                "-framework",
                "Virtualization",
                "-framework",
                "AppKit",
                RESOURCES / "Installer.swift",
                "-o",
                native,
            ],
        )
        subprocess.check_call(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--entitlements",
                RESOURCES / "entitlements.plist",
                native,
            ],
        )
        (bundle / "toolchain.json").write_text(
            json.dumps(
                {
                    "sdkVersion": sdk,
                    "swift": subprocess.check_output(
                        ["/usr/bin/xcrun", "swiftc", "--version"], text=True
                    ).strip(),
                    "vfkit": subprocess.check_output(["vfkit", "--version"], text=True).strip(),
                    "installerSha256": checksum(RESOURCES / "Installer.swift"),
                    "orchestratorSha256": checksum(Path(__file__)),
                    "provisionerSha256": checksum(RESOURCES / "provision.sh"),
                },
                indent=2,
            )
            + "\n"
        )
        ipsw = fetch(recipe["ipsw"], cache, suffix=".ipsw")
        nix_archive = fetch(recipe["nix"], cache)
        subprocess.check_call([native, "install", bundle, ipsw], timeout=args.install_timeout)
        wait_for_storage(bundle)
        password_file = temporary / "password"
        password_file.write_text(secrets.token_urlsafe(32))
        password_file.chmod(0o600)
        askpass = temporary / "askpass"
        askpass.write_text("#!/bin/sh\nexec /bin/cat " + shlex.quote(str(password_file)) + "\n")
        askpass.chmod(0o700)
        password_env = {
            **os.environ,
            "SSH_ASKPASS": str(askpass),
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
        }
        guest = Guest(user, identity, temporary)
        process = None
        try:
            with (temporary / "provision.log").open("w") as log:
                print(
                    "Booting with Apple's first-boot account and SSH provisioning...",
                    flush=True,
                )
                process = subprocess.Popen(
                    [native, "provision", bundle, password_file],
                    stdout=log,
                    stderr=log,
                )
                guest.wait(process, image["macAddress"], password_env)
                guest.ssh(
                    "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys",
                    password_env,
                    input=public_key + "\n",
                )
                sudoers = f"{user} ALL=(ALL) NOPASSWD: ALL\n"
                setup = (
                    "mkdir -p /etc/sudoers.d; printf %s "
                    + shlex.quote(sudoers)
                    + " > /etc/sudoers.d/macos-image-bootstrap; chmod 440 /etc/sudoers.d/macos-image-bootstrap"
                )
                guest.ssh(
                    "sudo -S -p '' /bin/sh -c " + shlex.quote(setup),
                    input=password_file.read_text() + "\n",
                )
                password_file.unlink()
                print(
                    "Installing Nix and applying the locked guest configuration...",
                    flush=True,
                )
                guest.ssh("umask 077; mkdir -p ~/macos-image-build")
                source_tar = temporary / "source.tar"
                with tarfile.open(source_tar, "w") as archive:
                    archive.add(snapshot, arcname="source")
                guest.copy(source_tar, "macos-image-build/source.tar")
                guest.copy(nix_archive, "macos-image-build/nix.tar.xz")
                guest.copy(RESOURCES / "provision.sh", "macos-image-build/provision.sh")
                guest.ssh(
                    shlex.join(
                        [
                            "/bin/sh",
                            "macos-image-build/provision.sh",
                            "./source#" + recipe["target"],
                            "./source#darwinConfigurations."
                            + json.dumps(recipe["target"])
                            + ".system",
                        ]
                    ),
                    timeout=args.provision_timeout,
                )
                guest.shutdown(process)
            wait_for_storage(bundle)
            print("Booting the installed bundle under standalone vfkit...", flush=True)
            with (temporary / "vfkit.log").open("w") as log:
                process = subprocess.Popen(vfkit_arguments(bundle, image), stdout=log, stderr=log)
                guest.wait(process, image["macAddress"])
                install_fonts(guest, fonts, font_staging)
                print("Running home-bootstrap in the configured guest...", flush=True)
                with (temporary / "bootstrap.log").open("w") as bootstrap_log:
                    image["bootstrap"] = bootstrap_home(guest, args.provision_timeout, bootstrap_log)
                (bundle / "image.json").write_text(json.dumps(image, indent=2) + "\n")
                guest.ssh("""set -eu
test "$(sw_vers -productVersion | cut -d. -f1)" -ge 27
test -e /etc/mjr-vm-guest
test -L /run/current-system
test "$(/usr/bin/dscl . -read "/Users/$(id -un)" UserShell)" = 'UserShell: /run/current-system/sw/bin/fish'
env TERM=xterm-ghostty /run/current-system/sw/bin/fish --login --interactive --command '
    /usr/bin/infocmp -x xterm-ghostty >/dev/null
    and test "$TERM" = xterm-ghostty
    and test (/usr/bin/tput colors) -ge 256
'
/nix/var/nix/profiles/default/bin/nix --version
sudo -n true
chmod -R u+w ~/macos-image-build/source
rm -rf ~/macos-image-build
""")
                guest.shutdown(process)
            for name in ("provision.log", "vfkit.log", "bootstrap.log"):
                shutil.copyfile(temporary / name, bundle / name)
            publish_bundle(bundle, destination)
        except BaseException:
            for name in ("provision.log", "vfkit.log", "bootstrap.log"):
                path = temporary / name
                if path.exists():
                    print(
                        f"\n{name} (last 4000 characters):\n{path.read_text()[-4000:]}",
                        file=sys.stderr,
                    )
            raise
        finally:
            stop_process(process)
    print(f"Validated macOS bundle: {destination}")


def main():
    parser = argparse.ArgumentParser(
        prog="bake-macos",
        description="Install and configure a macOS 27 VM, then validate it under vfkit.",
    )
    parser.add_argument(
        "--flake",
        type=Path,
        default=Path.cwd(),
        help="system configuration flake containing macosImage (default: current directory)",
    )
    parser.add_argument("--identity", type=Path, default=Path("~/.ssh/id_ed25519"))
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(os.environ.get("VMS_DIR", "~/vms")) / "golden-aarch64-darwin",
    )
    parser.add_argument("--cache", type=Path, default=Path("~/Library/Caches/bake-macos"))
    parser.add_argument(
        "--list-host-fonts", action="store_true",
        help="list installed user/system font families and available license metadata as JSON, without baking",
    )
    font_options = parser.add_mutually_exclusive_group()
    font_options.add_argument(
        "--font-family", action="append",
        help="font family to copy if installed; repeat to select multiple families; replaces macosImage.fontFamilies",
    )
    font_options.add_argument("--no-host-fonts", action="store_true", help="disable copying host fonts")
    parser.add_argument("--install-timeout", type=int, default=3600)
    parser.add_argument("--provision-timeout", type=int, default=7200)
    parser.add_argument(
        "--check",
        action="store_true",
        help="evaluate and validate the flake's macosImage output without downloading VM artifacts or starting a VM",
    )
    args = parser.parse_args()
    try:
        if args.list_host_fonts:
            print(json.dumps(discover_fonts(host_font_directories()), indent=2))
            return
        if args.font_family is not None and any(not family.strip() for family in args.font_family):
            raise ValueError("--font-family must not be empty")
        metadata, recipe = load_configuration(args.flake.expanduser().resolve())
        if args.check:
            print("Recipe is valid")
        else:
            bake(args, metadata, recipe)
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        parser.exit(1, f"bake-macos: {error}\n")


if __name__ == "__main__":
    main()
