import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import agent


class AgentTests(unittest.TestCase):
    def test_lsof_fields_preserve_process_names_and_distinguish_addresses(self):
        data = (
            b'p12\0cweb server\0\nf3\0n*:8080\0\nf4\0n*:8080\0\n'
            b'p13\0clocal\0\nf5\0n127.0.0.1:8081\0\nf6\0n[::1]:8082\0\nf7\0n[fe80::1%en0]:8083\0\n'
            b'p14\0csshd\0\nf8\0n*:22\0\n'
        )
        listeners = agent.parse_listeners(data)
        self.assertEqual(len(listeners), 5)
        self.assertEqual(listeners[0], {"proto": "tcp", "addr": "*", "port": 8080, "pid": 12, "process": "web server"})
        self.assertEqual([row["addr"] for row in listeners[1:]], ["127.0.0.1", "::1", "fe80::1", "*"])
        for invalid in (b"nlocalhost:8080\0", b"n*:0\0", b"n*:65536\0", b"ninvalid\0"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                agent.parse_listeners(invalid)

    def test_empty_selection_is_valid_but_failed_or_partial_scan_is_not(self):
        with patch.object(agent.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, b"", b"")
            report = agent.report_ports()
            self.assertEqual(report["listeners"], [])
            self.assertEqual(report["schemaVersion"], 1)
            self.assertTrue(report["generatedAt"].endswith("Z"))
            for status, output, error in ((1, b"", b"denied"), (0, b"n*:80\0", b"partial scan"), (2, b"", b"")):
                run.return_value = subprocess.CompletedProcess([], status, output, error)
                with self.subTest(status=status, error=error), self.assertRaises(RuntimeError):
                    agent.report_ports()

    def test_mount_conflicts_and_readonly_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "source files"
            mounts = {}
            with patch.object(agent.subprocess, "run") as run:
                agent.mount_share("src", target, True, mounts)
                run.assert_called_once_with(["/sbin/mount_virtiofs", "-o", "ro", "src", str(target)], check=True, capture_output=True, text=True, timeout=15)
                agent.mount_share("src", target, True, mounts)
                self.assertEqual(run.call_count, 1)
                for current in (("src", ["virtiofs"]), ("other", ["virtiofs", "read-only"]), ("src", ["apfs"])):
                    mounts[str(target.resolve())] = current
                    with self.subTest(current=current), self.assertRaises(RuntimeError):
                        agent.mount_share("src", target, True, mounts)
                self.assertEqual(run.call_count, 1)
                with self.assertRaises(ValueError):
                    agent.mount_share("src", "/", False, {})
                with self.assertRaises(ValueError):
                    agent.mount_share("src", agent.CONTROL / "nested", False, {})

    def test_mount_listing_handles_spaces_and_aliases(self):
        listing = "voom-control on /private/var/run/voom (virtiofs, local)\nsrc on /Volumes/a on b (files) (virtiofs, local, read-only)\n"
        with patch.object(agent.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, listing)):
            mounts = agent.mounted_filesystems()
        self.assertEqual(mounts["/Volumes/a on b (files)"], ("src", ["virtiofs", "local", "read-only"]))

    def test_failed_publish_preserves_the_previous_report(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, "CONTROL", Path(directory)):
            agent.publish_report({"listeners": []})
            with patch.object(agent.Path, "replace", side_effect=OSError("disconnected share")):
                with self.assertRaises(OSError):
                    agent.publish_report({"listeners": [{"port": 8080}]})
            self.assertEqual(json.loads((agent.CONTROL / "ports.json").read_text()), {"listeners": []})
            self.assertEqual([path.name for path in agent.CONTROL.iterdir()], ["ports.json"])
