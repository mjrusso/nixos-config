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
from contextlib import redirect_stdout
from pathlib import Path
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
    def test_guest_service_probe_checks_roundtrip_and_removes_its_mounts(self):
        from datetime import datetime, timezone
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shares = bake.prepare_guest_service_check(root)
            args = bake.vfkit_arguments(root, {"cpuCount": 4, "memoryMiB": 8192, "macAddress": "02:00:00:00:00:01"}, shares)
            self.assertTrue(any("mountTag=voom-control" in argument for argument in args))
            (root / "voom-share-check" / "from-guest").write_text("guest-write\n")
            report = {"schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).isoformat(), "listeners": [{"proto": "tcp", "port": 22}]}
            (root / "voom-control" / "ports.json").write_text(json.dumps(report))
            guest = Mock()
            bake.verify_guest_services(guest, root)
            self.assertEqual(json.loads((root / "voom-control" / "mounts.json").read_text()), [])
            self.assertIn("umount", guest.ssh.call_args.args[0])

    def test_guest_service_probe_rejects_failed_readonly_enforcement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bake.prepare_guest_service_check(root)
            (root / "voom-share-check" / "from-guest").write_text("guest-write\n")
            (root / "voom-share-check" / "forbidden-write").touch()
            with self.assertRaisesRegex(ValueError, "share validation"):
                bake.verify_guest_services(Mock(), root)

    def test_guest_capabilities_require_the_installed_service_contract(self):
        guest = Mock()
        capabilities = {"controlShare": True, "guestPortReport": True, "guestShareMount": True, "nixosSwitch": False}
        guest.ssh.return_value = subprocess.CompletedProcess([], 0, json.dumps({"schemaVersion": 1, "capabilities": capabilities}))
        self.assertEqual(bake.guest_capabilities(guest), capabilities)
        for services in ({}, {"schemaVersion": 2, "capabilities": capabilities}, {"schemaVersion": 1, "capabilities": {"controlShare": True}}):
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
