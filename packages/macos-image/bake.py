import argparse
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
from pathlib import Path

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
    return recipe


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


def fetch(artifact, cache):
    expected = artifact["sha256"].lower()
    destination = cache / expected
    if destination.exists() and checksum(destination) == expected:
        return destination
    print(f"Downloading {artifact['url']}", flush=True)
    descriptor, name = tempfile.mkstemp(prefix=expected + ".", suffix=".partial", dir=cache)
    os.close(descriptor)
    partial = Path(name)
    try:
        with (
            urllib.request.urlopen(artifact["url"], timeout=60) as response,
            partial.open("wb") as stream,
        ):
            shutil.copyfileobj(response, stream, 1024 * 1024)
        if checksum(partial) != expected:
            raise ValueError(f"SHA-256 mismatch for {artifact['url']}")
        partial.replace(destination)
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
        deadline = time.monotonic() + timeout
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
                        stderr=subprocess.DEVNULL,
                        timeout=15,
                    )
                    return
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    pass
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


def stop_process(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


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
    destination = args.output.expanduser().resolve()
    if destination.exists():
        raise ValueError(f"Output already exists: {destination}; choose a new --output")
    if "," in str(destination):
        raise ValueError("The output path cannot contain a comma (vfkit option delimiter)")
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache = args.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".bake-macos-", dir=destination.parent) as work:
        temporary = Path(work)
        bundle = temporary / "image"
        bundle.mkdir()
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
                "5",
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
        ipsw = fetch(recipe["ipsw"], cache)
        nix_archive = fetch(recipe["nix"], cache)
        subprocess.check_call([native, "install", bundle, ipsw], timeout=args.install_timeout)
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
                    + " > /etc/sudoers.d/voom-image-bootstrap; chmod 440 /etc/sudoers.d/voom-image-bootstrap"
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
                guest.ssh("umask 077; mkdir -p ~/voom-image-build")
                source_tar = temporary / "source.tar"
                with tarfile.open(source_tar, "w") as archive:
                    archive.add(snapshot, arcname="source")
                guest.copy(source_tar, "voom-image-build/source.tar")
                guest.copy(nix_archive, "voom-image-build/nix.tar.xz")
                guest.copy(RESOURCES / "provision.sh", "voom-image-build/provision.sh")
                guest.ssh(
                    shlex.join(
                        [
                            "/bin/sh",
                            "voom-image-build/provision.sh",
                            "./source#" + recipe["target"],
                            "./source#darwinConfigurations."
                            + json.dumps(recipe["target"])
                            + ".system",
                        ]
                    ),
                    timeout=args.provision_timeout,
                )
                guest.shutdown(process)
            print("Booting the installed bundle under standalone vfkit...", flush=True)
            with (temporary / "vfkit.log").open("w") as log:
                process = subprocess.Popen(vfkit_arguments(bundle, image), stdout=log, stderr=log)
                guest.wait(process, image["macAddress"])
                guest.ssh("""set -eu
test "$(sw_vers -productVersion | cut -d. -f1)" -ge 27
test -e /etc/mjr-vm-guest
test -L /run/current-system
/nix/var/nix/profiles/default/bin/nix --version
sudo -n true
rm -rf ~/voom-image-build
""")
                guest.shutdown(process)
            for name in ("provision.log", "vfkit.log"):
                shutil.copyfile(temporary / name, bundle / name)
            bundle.rename(destination)
        except BaseException:
            for name in ("provision.log", "vfkit.log"):
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
    parser.add_argument("--install-timeout", type=int, default=3600)
    parser.add_argument("--provision-timeout", type=int, default=7200)
    parser.add_argument(
        "--check",
        action="store_true",
        help="evaluate and validate the flake's macosImage output without downloading VM artifacts or starting a VM",
    )
    args = parser.parse_args()
    try:
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
