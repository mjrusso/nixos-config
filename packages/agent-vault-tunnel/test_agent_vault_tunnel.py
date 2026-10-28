import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


PF = '''
import json, pathlib, sys
state_file = pathlib.Path(sys.argv[0]).with_name("pf-state.json")
state = json.loads(state_file.read_text())
args = sys.argv[1:]
if args == ["-sr"]:
    print(state["root"])
elif args == ["-s", "info"]:
    print("Status: " + ("Enabled" if state["enabled"] else "Disabled"))
elif args == ["-E"]:
    state["enabled"] = True
    print("Token : 1234", file=sys.stderr)
elif args == ["-X", "1234"]:
    state["enabled"] = False
elif "-sr" in args:
    print(state["rule"])
elif "-f" in args:
    value = sys.stdin.read().strip()
    state["rule"] = value
else:
    sys.exit(2)
if args[0] in ("-E", "-X") or "-f" in args:
    state_file.write_text(json.dumps(state))
'''

SSH = '''
import json, os, pathlib, socket, sys
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
pathlib.Path(sys.argv[0]).with_name("ssh-state.json").write_text(json.dumps({
    "pid": os.getpid(), "port": listener.getsockname()[1], "args": sys.argv[1:]
}))
while True:
    connection, _ = listener.accept()
    connection.close()
'''


class TunnelTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name, source in (("pfctl", PF), ("ssh", SSH)):
            path = self.root / name
            path.write_text(f"#!{sys.executable}\n" + source)
            path.chmod(0o700)
        self.state_file = self.root / "pf-state.json"
        self.state_file.write_text(json.dumps({
            "root": 'anchor "com.apple/*" all', "enabled": True, "rule": "",
        }))
        self.config = {
            "pfctl": str(self.root / "pfctl"), "ssh": str(self.root / "ssh"),
            "listenAddress": "192.0.2.1", "port": 3128, "host": "linux-host",
            "identityFile": "/private/key", "knownHostsFile": "/private/known_hosts",
        }

    def change_pf(self, **changes):
        state = json.loads(self.state_file.read_text())
        state.update(changes)
        temporary = self.root / "pf-new.json"
        temporary.write_text(json.dumps(state))
        temporary.replace(self.state_file)

    def start(self):
        config_file = self.root / "config.json"
        config_file.write_text(json.dumps(self.config))
        self.process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("agent_vault_tunnel.py")), str(config_file)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.cleanup_process)

    def cleanup_process(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.communicate(timeout=10)

    def wait_for_ssh(self):
        path = self.root / "ssh-state.json"
        deadline = time.monotonic() + 5
        while not path.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail(self.process.communicate()[1])
            time.sleep(0.02)
        self.assertTrue(path.exists(), "SSH was not started")
        state = json.loads(path.read_text())
        with socket.create_connection(("127.0.0.1", state["port"]), timeout=1):
            pass
        return state

    def test_rejects_missing_root_anchor_before_starting_ssh(self):
        self.change_pf(root="")
        self.start()
        _, error = self.process.communicate(timeout=5)
        self.assertNotEqual(self.process.returncode, 0)
        self.assertIn("standard /etc/pf.conf", error)
        self.assertFalse((self.root / "ssh-state.json").exists())

    def test_removing_restriction_closes_listener(self):
        self.start()
        state = self.wait_for_ssh()
        self.assertIn("StrictHostKeyChecking=yes", state["args"])
        self.assertIn("192.0.2.1:3128:/run/agent-vault-shared-proxy/proxy.sock", state["args"])
        self.change_pf(rule="")
        _, error = self.process.communicate(timeout=8)
        self.assertNotEqual(self.process.returncode, 0)
        self.assertIn("restriction is missing", error)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", state["port"]), timeout=1)

    def test_disabling_pf_closes_listener(self):
        self.start()
        state = self.wait_for_ssh()
        self.change_pf(enabled=False)
        _, error = self.process.communicate(timeout=8)
        self.assertIn("PF is disabled", error)
        with self.assertRaises(ProcessLookupError):
            os.kill(state["pid"], 0)

    def test_shutdown_closes_ssh_and_releases_only_its_pf_reference(self):
        self.change_pf(enabled=False)
        self.start()
        state = self.wait_for_ssh()
        self.assertEqual(os.getpgid(state["pid"]), os.getpgid(self.process.pid))
        self.process.send_signal(signal.SIGTERM)
        self.process.communicate(timeout=8)
        self.assertEqual(self.process.returncode, 0)
        self.assertFalse(json.loads(self.state_file.read_text())["enabled"])
        with self.assertRaises(ProcessLookupError):
            os.kill(state["pid"], 0)

    def test_shutdown_preserves_existing_pf_enablement(self):
        self.start()
        self.wait_for_ssh()
        self.process.terminate()
        self.process.communicate(timeout=8)
        self.assertTrue(json.loads(self.state_file.read_text())["enabled"])


if __name__ == "__main__":
    unittest.main()
