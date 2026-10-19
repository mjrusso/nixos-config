import ctypes
import errno
import fcntl
import hashlib
import io
import itertools
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import bake


RECIPE = {
    "ipsw": {"url": "https://example.com/restore.ipsw", "sha256": "a" * 64},
    "nix": {"url": "https://example.com/nix.tar.xz", "sha256": "b" * 64},
    "sdkVersion": "27.0",
    "target": "aarch64-darwin@vm",
    "cpuCount": 4,
    "memoryMiB": 8192,
    "diskGiB": 100,
}


class BakeTests(unittest.TestCase):
    def test_bake_publication_and_failure_recovery_without_integration_tests(self):
        recipe = bake.parse_recipe(RECIPE)
        for failure in (None, "boot checks", "bootstrap", "first SSH"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                snapshot = root / "source"
                snapshot.mkdir()
                (snapshot / "flake.nix").write_text("locked source")
                key = root / "key"
                key.write_text("private test key")
                Path(str(key) + ".pub").write_text("public test key")
                archive = root / "archive"
                archive.touch()
                args = SimpleNamespace(identity=key, output=root / "golden", cache=root / "cache",
                                       font_family=None, no_host_fonts=True, install_timeout=10, provision_timeout=10)
                if failure:
                    self.bundle(args.output, "existing image")
                capabilities = {"vsockControl": True, "controlShare": False, "guestPortReport": True, "guestShareMount": True, "nixosSwitch": False}
                stages, processes = [], []
                guest = Mock(spec=bake.Guest)

                def check_output(command, **kwargs):
                    if command[0] == "nix":
                        return json.dumps("user")
                    if "--show-sdk-version" in command:
                        return RECIPE["sdkVersion"]
                    return "tool version"

                def check_call(command, **kwargs):
                    if command[1] == "install":
                        for name in ("disk.raw", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "restore.json"):
                            (command[2] / name).write_text("installed guest")

                def start_process(command, **kwargs):
                    self.assertFalse(any("virtio-fs" in str(argument) for argument in command))
                    kwargs["stdout"].write("VM log\n")
                    process = Mock(returncode=None)
                    process.poll.side_effect = lambda: process.returncode

                    def wait(**kwargs):
                        process.returncode = 0
                        return 0

                    process.wait.side_effect = wait
                    processes.append(process)
                    return process

                def ssh(command, *positional, **kwargs):
                    self.assertNotIn("/Volumes/voom-check", command)
                    if "UserShell" in command:
                        stages.append("boot checks")
                    elif "--command home-bootstrap" in command:
                        self.assertIn("boot checks", stages)
                        stages.append("bootstrap")
                        kwargs["stdout"].write("bootstrap output\n")
                    else:
                        if "guest-services.json" in command:
                            return subprocess.CompletedProcess([], 0, json.dumps({"schemaVersion": 1, "capabilities": capabilities}))
                        return subprocess.CompletedProcess([], 0, "a" * 40)
                    if stages[-1] == failure:
                        raise RuntimeError(failure)
                    return subprocess.CompletedProcess([], 0)

                guest.ssh.side_effect = ssh
                guest.shutdown.side_effect = lambda process: process.wait()
                if failure == "first SSH":
                    guest.wait.side_effect = RuntimeError(failure)
                output = io.StringIO()
                with ExitStack() as stack:
                    for target, replacement in (
                        ("platform.system", lambda: "Darwin"),
                        ("platform.machine", lambda: "arm64"),
                        ("platform.mac_ver", lambda: ("27.0", "", "")),
                        ("shutil.which", lambda command: "/bin/" + command),
                        ("subprocess.check_output", check_output),
                        ("subprocess.check_call", check_call),
                        ("subprocess.Popen", start_process),
                        ("fetch", lambda *args, **kwargs: archive),
                        ("Guest", lambda *args: guest),
                    ):
                        stack.enter_context(patch("bake." + target, replacement))
                    stack.enter_context(redirect_stdout(output))
                    stack.enter_context(redirect_stderr(output))
                    if failure:
                        with self.assertRaisesRegex(RuntimeError, failure):
                            bake.bake(args, {"path": str(snapshot)}, recipe)
                    else:
                        bake.bake(args, {"path": str(snapshot)}, recipe)
                self.assertTrue(all(process.returncode == 0 for process in processes))
                workspaces = list(root.glob(".bake-macos-*"))
                if failure:
                    self.assertEqual((args.output / "disk.raw").read_text(), "existing image")
                    self.assertEqual(len(workspaces), 1)
                    work = workspaces[0]
                    self.assertEqual((work / "image/disk.raw").read_text(), "installed guest")
                    self.assertEqual((work / "provision.log").read_text(), "VM log\n")
                    self.assertFalse((work / "password").exists())
                    self.assertIn(str(work), output.getvalue())
                    if failure == "boot checks":
                        self.assertNotIn("bootstrap", stages)
                    elif failure == "bootstrap":
                        self.assertEqual((work / "bootstrap.log").read_text(), "bootstrap output\n")
                else:
                    self.assertEqual(workspaces, [])
                    image = json.loads((args.output / "image.json").read_text())
                    self.assertEqual(image["capabilities"], capabilities)
                    self.assertEqual(image["bootstrap"]["repositories"]["emacs"]["revision"], "a" * 40)
                    for name in ("provision.log", "vfkit.log", "bootstrap.log"):
                        self.assertTrue((args.output / name).read_text())

    def test_failed_bake_keeps_workspace_and_reports_its_path(self):
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                with self.assertRaisesRegex(RuntimeError, "validation failed"):
                    with bake.build_workspace(Path(directory)) as work:
                        (work / "image").mkdir()
                        (work / "image/disk.raw").write_text("installed guest")
                        (work / "bootstrap.log").write_text("bootstrap completed")
                        (work / "password").write_text("temporary account password")
                        raise RuntimeError("validation failed")
            self.assertEqual((work / "image/disk.raw").read_text(), "installed guest")
            self.assertEqual((work / "bootstrap.log").read_text(), "bootstrap completed")
            self.assertFalse((work / "password").exists())
            self.assertIn(f"Bake failed; workspace retained at: {work}", output.getvalue())

    def test_successful_bake_removes_workspace(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
            with bake.build_workspace(Path(directory)) as work:
                (work / "bootstrap.log").write_text("bootstrap completed")
            self.assertFalse(work.exists())

    def test_shutdown_accepts_ssh_disconnect_when_vm_exits_successfully(self):
        guest = bake.Guest("user", Path("key"), Path("/tmp"))
        guest.address = "192.0.2.1"
        process = Mock(returncode=0)
        with patch("bake.subprocess.run", side_effect=subprocess.CalledProcessError(255, "ssh")):
            guest.shutdown(process)
        process.wait.assert_called_once_with(timeout=180)

    def test_shutdown_rejects_command_errors_and_failed_or_stalled_vms(self):
        for ssh_status, vm_status, wait_error, expected in (
            (1, 0, None, subprocess.CalledProcessError),
            (255, 1, None, RuntimeError),
            (0, 1, None, RuntimeError),
            (255, None, subprocess.TimeoutExpired("vm", 180), subprocess.TimeoutExpired),
        ):
            with self.subTest(ssh_status=ssh_status, vm_status=vm_status, wait_error=wait_error):
                guest = bake.Guest("user", Path("key"), Path("/tmp"))
                guest.address = "192.0.2.1"
                process = Mock(returncode=vm_status)
                process.wait.side_effect = wait_error
                ssh_result = subprocess.CompletedProcess([], 0)
                ssh_error = subprocess.CalledProcessError(ssh_status, "ssh") if ssh_status else None
                with patch("bake.subprocess.run", return_value=ssh_result, side_effect=ssh_error):
                    with self.assertRaises(expected):
                        guest.shutdown(process)

    def test_guest_capabilities_require_the_installed_service_contract(self):
        guest = Mock()
        capabilities = {"vsockControl": True, "controlShare": False, "guestPortReport": True, "guestShareMount": True, "nixosSwitch": False}
        guest.ssh.return_value = subprocess.CompletedProcess([], 0, json.dumps({"schemaVersion": 1, "capabilities": capabilities}))
        self.assertEqual(bake.guest_capabilities(guest), capabilities)
        for services in ({}, {"schemaVersion": 2, "capabilities": capabilities}, {"schemaVersion": 1, "capabilities": {"vsockControl": True, "controlShare": False}}):
            guest.ssh.return_value.stdout = json.dumps(services)
            with self.subTest(services=services), self.assertRaises(ValueError):
                bake.guest_capabilities(guest)

    def test_bootstrap_records_git_revisions_from_guest(self):
        guest = Mock()
        guest.ssh.side_effect = [
            None,
            subprocess.CompletedProcess([], 0, stdout="a" * 40 + "\n"),
            subprocess.CompletedProcess([], 0, stdout="b" * 64 + "\n"),
        ]
        result = bake.bootstrap_home(guest, 7200, io.StringIO())
        self.assertEqual(result, {
            "repositories": {
                "emacs": {"directory": ".emacs.d", "revision": "a" * 40},
                "wingman": {"directory": "git/github.com/mjrusso/wingman", "revision": "b" * 64},
            }
        })

    def test_bootstrap_rejects_missing_git_revision(self):
        guest = Mock()
        guest.ssh.side_effect = [None, subprocess.CompletedProcess([], 0, stdout="")]
        with self.assertRaisesRegex(ValueError, "bootstrap Git revision"):
            bake.bootstrap_home(guest, 7200, io.StringIO())

    def bundle(self, path, contents):
        path.mkdir()
        for name in ("disk.raw", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "restore.json", "toolchain.json"):
            (path / name).write_text(contents)
        (path / "image.json").write_text(json.dumps({"system": "aarch64-darwin", "format": "macos-bundle"}))
        return path

    def test_publish_new_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = self.bundle(root / "staged", "new")
            destination = root / "golden"
            bake.publish_bundle(staged, destination)
            self.assertFalse(staged.exists())
            self.assertEqual((destination / "disk.raw").read_text(), "new")

    def test_publish_refuses_unrelated_outputs_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = self.bundle(root / "staged", "new")
            unrelated = root / "unrelated"
            unrelated.mkdir()
            (unrelated / "keep").write_text("keep")
            alias = root / "alias"
            alias.symlink_to(unrelated)
            file = root / "file"
            file.write_text("keep")
            for destination in (unrelated, alias, file):
                with self.subTest(destination=destination), self.assertRaises((ValueError, OSError)):
                    bake.publish_bundle(staged, destination)
                self.assertEqual((staged / "disk.raw").read_text(), "new")
            self.assertEqual((unrelated / "keep").read_text(), "keep")
            self.assertEqual(file.read_text(), "keep")

    def test_publish_preserves_existing_bundle_when_storage_is_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = self.bundle(root / "staged", "new")
            destination = self.bundle(root / "golden", "old")
            for name in ("disk.raw", "AuxiliaryStorage"):
                with self.subTest(name=name), (destination / name).open("r+b") as holder:
                    fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with self.assertRaises(BlockingIOError):
                        bake.publish_bundle(staged, destination)
                    self.assertEqual((destination / "disk.raw").read_text(), "old")
                    self.assertEqual((staged / "disk.raw").read_text(), "new")

    def test_publish_waits_for_staged_storage_before_exposing_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("disk.raw", "AuxiliaryStorage"):
                staged = self.bundle(root / ("staged-" + name), "new")
                destination = root / ("golden-" + name)
                with self.subTest(name=name), (staged / name).open("r+b") as holder:
                    fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)

                    def release_storage(_):
                        self.assertFalse(destination.exists())
                        fcntl.flock(holder, fcntl.LOCK_UN)

                    with patch("bake.time.sleep", side_effect=release_storage) as sleep:
                        bake.publish_bundle(staged, destination)
                    sleep.assert_called_once()
                    self.assertEqual((destination / "disk.raw").read_text(), "new")

    def test_failed_native_swap_preserves_both_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = self.bundle(root / "staged", "new")
            destination = self.bundle(root / "golden", "old")
            with patch("bake.ctypes.CDLL") as library:
                library.return_value.renamex_np.return_value = -1
                ctypes.set_errno(errno.ENOTSUP)
                with self.assertRaises(OSError):
                    bake.publish_bundle(staged, destination)
            self.assertEqual((destination / "disk.raw").read_text(), "old")
            self.assertEqual((staged / "disk.raw").read_text(), "new")
            with bake.locked_storage(destination):
                pass

    @unittest.skipUnless(sys.platform == "darwin", "requires MacOS renamex_np")
    def test_native_swap_publishes_complete_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = self.bundle(root / "staged", "new")
            destination = self.bundle(root / "golden", "old")
            bake.publish_bundle(staged, destination)
            for name in ("disk.raw", "AuxiliaryStorage", "MachineIdentifier", "HardwareModel"):
                self.assertEqual((destination / name).read_text(), "new")
                self.assertEqual((staged / name).read_text(), "old")

    def test_storage_handoff_waits_for_each_file_and_releases_its_own_locks(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            files = [bundle / name for name in ("AuxiliaryStorage", "disk.raw")]
            for path in files:
                path.write_bytes(b"storage")
            for path in files:
                with self.subTest(path=path.name), path.open("r+b") as holder:
                    fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    output = io.StringIO()
                    with (
                        patch("bake.time.sleep", side_effect=lambda _: fcntl.flock(holder, fcntl.LOCK_UN)) as sleep,
                        redirect_stdout(output),
                    ):
                        bake.wait_for_storage(bundle)
                    sleep.assert_called_once()
                    self.assertIn(path.name, output.getvalue())
                    for released in files:
                        with released.open("r+b") as stream:
                            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_storage_handoff_times_out_when_a_lock_is_not_released(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            path = bundle / "AuxiliaryStorage"
            path.write_bytes(b"storage")
            with path.open("r+b") as holder:
                fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch("bake.time.monotonic", side_effect=[0, 1]):
                    with self.assertRaisesRegex(TimeoutError, "AuxiliaryStorage"):
                        bake.wait_for_storage(bundle, timeout=1)

    def test_ipsw_cache_keeps_its_extension_and_reuses_existing_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            contents = b"pinned restore image"
            digest = hashlib.sha256(contents).hexdigest()
            legacy = cache / digest
            legacy.write_bytes(contents)
            inode = legacy.stat().st_ino
            artifact = {"url": "https://example.com/download", "sha256": digest}
            with patch("bake.urllib.request.urlopen", side_effect=AssertionError("downloaded again")):
                destination = bake.fetch(artifact, cache, suffix=".ipsw")
                self.assertEqual(bake.fetch(artifact, cache, suffix=".ipsw"), destination)
            self.assertEqual(destination.suffix, ".ipsw")
            self.assertEqual(destination.read_bytes(), contents)
            self.assertEqual(destination.stat().st_ino, inode)
            self.assertFalse(legacy.exists())

    def test_download_reports_progress_before_completion_with_or_without_a_size(self):
        contents = b"x" * (2 * 1024 * 1024)
        for known_size in (True, False):
            with self.subTest(known_size=known_size), tempfile.TemporaryDirectory() as directory:
                response = io.BytesIO(contents)
                response.headers = {"Content-Length": str(len(contents))} if known_size else {}
                output = io.StringIO()
                read = response.read

                def read_chunk(size):
                    if response.tell():
                        self.assertIn("Downloaded ", output.getvalue())
                    return read(size)

                artifact = {
                    "url": "https://example.com/restore.ipsw",
                    "sha256": hashlib.sha256(contents).hexdigest(),
                }
                with (
                    patch("bake.urllib.request.urlopen", return_value=response),
                    patch.object(response, "read", side_effect=read_chunk),
                    patch("bake.time.monotonic", side_effect=itertools.count(0, 6)),
                    redirect_stdout(output),
                ):
                    destination = bake.fetch(artifact, Path(directory))
                self.assertEqual(destination.read_bytes(), contents)
                self.assertIn("MiB/s", output.getvalue())
                self.assertIn("Verifying SHA-256", output.getvalue())
                if known_size:
                    self.assertIn("%", output.getvalue())
                    self.assertIn("ETA", output.getvalue())
                else:
                    self.assertNotIn("%", output.getvalue())
                    self.assertNotIn("ETA", output.getvalue())

    def test_configuration_accepts_relative_inputs_and_rejects_host_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            flake = Path(directory)
            (flake / "flake.lock").write_text("{}")
            for path, parent, accepted in (
                ("./agent-skills", [], True),
                ("../sibling", ["remote", "child"], True),
                ("/home/user/agent-skills", None, False),
                ("/nix/store/host-only-source", None, False),
                ("./agent-skills", None, False),
                ("/home/user/agent-skills", [], False),
            ):
                node = {"locked": {"type": "path", "path": path}}
                if parent is not None:
                    node["parent"] = parent
                metadata = {
                    "path": "/nix/store/config-snapshot",
                    "locks": {"nodes": {"agent-skills": node}},
                }
                with self.subTest(path=path, parent=parent), patch(
                    "bake.subprocess.check_output",
                    side_effect=[json.dumps(metadata), json.dumps(RECIPE)],
                ):
                    if accepted:
                        self.assertEqual(bake.load_configuration(flake), (metadata, {**RECIPE, "fontFamilies": []}))
                    else:
                        with self.assertRaisesRegex(ValueError, "agent-skills"):
                            bake.load_configuration(flake)

    def test_verified_download_is_cached_and_corrupt_cache_is_repaired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "restore.ipsw"
            source.write_bytes(b"pinned restore image")
            cache = root / "cache"
            cache.mkdir()
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            artifact = {"url": source.as_uri(), "sha256": digest}
            destination = bake.fetch(artifact, cache)
            destination.write_bytes(b"corrupted")
            self.assertEqual(bake.fetch(artifact, cache).read_bytes(), source.read_bytes())
            source.unlink()
            self.assertEqual(bake.fetch(artifact, cache), destination)

    def test_checksum_mismatch_never_enters_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "restore.ipsw"
            source.write_bytes(b"unexpected content")
            cache = root / "cache"
            cache.mkdir()
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                bake.fetch({"url": source.as_uri(), "sha256": "0" * 64}, cache)
            self.assertEqual(list(cache.iterdir()), [])

    def test_recipe_rejects_unpinned_artifacts_and_invalid_resources(self):
        recipe = RECIPE
        bake.parse_recipe(recipe)
        for changes in (
            {"ipsw": {**recipe["ipsw"], "sha256": "latest"}},
            {"diskGiB": -1},
            {"cpuCount": True},
            {"sdkVersion": "latest"},
            {"fontFamilies": "Berkeley Mono"},
            {"fontFamilies": [""]},
            {"fontFamilies": [42]},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                bake.parse_recipe({**recipe, **changes})

    def test_dhcp_matches_the_vm_with_unpadded_mac_and_ignores_other_leases(self):
        leases = """{
ip_address=192.168.64.2
hw_address=1,2:0:a:b:c:d
}
{
ip_address=192.168.64.3
hw_address=1,2:0:a:b:c:e
}
{
ip_address=not-an-address
hw_address=1,2:0:a:b:c:d
}
"""
        self.assertEqual(bake.lease_address(leases, "02:00:0a:0b:0c:0d"), "192.168.64.2")
        self.assertIsNone(bake.lease_address(leases, "02:ff:ff:ff:ff:ff"))


if __name__ == "__main__":
    unittest.main()
