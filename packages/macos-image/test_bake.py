import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
                        self.assertEqual(bake.load_configuration(flake), (metadata, RECIPE))
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
