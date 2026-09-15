import contextlib
import importlib.util
import io
import json
import os
import pathlib
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("voom_agent_vault.py")
SPEC = importlib.util.spec_from_file_location("voom_agent_vault", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TestManager(MODULE.Manager):
    def __init__(self, root, haproxy):
        self.root = pathlib.Path(root)
        runtime = self.root / "runtime"
        runtime.mkdir()
        config = self.root / "config.json"
        config.write_text(
            json.dumps(
                {
                    "agentVault": "/bin/true",
                    "assignments": {},
                    "caPath": str(self.root / "ca.pem"),
                    "haproxy": haproxy,
                    "runtimeDir": str(runtime / "voom-agent-vault"),
                    "stateDir": str(self.root / "state"),
                    "voom": "/bin/true",
                }
            )
        )
        super().__init__(config)


class ManagerTests(unittest.TestCase):
    def simulated_voom(self, manager, vm_id, running=False, declaration=None):
        state = {"running": running, "declaration": declaration}

        def vm_info(name):
            return {
                "running": state["running"],
                "vm": {
                    "id": vm_id,
                    "network": {"egress": state["declaration"]},
                },
            }

        def voom_egress(action, name, expected_id, *arguments):
            self.assertEqual(vm_id, expected_id)
            if action == "set":
                state["declaration"] = {
                    "mode": "explicit",
                    "backendSocket": arguments[arguments.index("--backend-socket") + 1],
                    "caCertPath": arguments[arguments.index("--ca-cert") + 1],
                    "enabled": "--disabled" not in arguments,
                }
            elif action == "enable":
                state["declaration"]["enabled"] = True
            elif action == "disable":
                state["declaration"]["enabled"] = False
            elif action == "clear":
                state["declaration"] = None
            return {}

        manager.vm_info = vm_info
        manager.voom_egress = voom_egress
        manager.ensure_agent = lambda attachment: (
            None if manager.valid_token_file(vm_id) else "av_agent_secret"
        )
        manager.reload_bridge = lambda: None
        manager.verify_socket = lambda attachment: None
        manager.verify_token = lambda attachment: None
        manager.ca_path.write_text("public CA")
        return state

    def test_agent_name_normalizes_voom_id(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "ABCDEF0123456789ABCDEF0123456789"
            attachment = manager.new_attachment("test", vm_id, "personal")
            self.assertEqual(
                "voom-abcdef0123456789abcdef0123456789", attachment["agentName"]
            )

    def test_configured_directories_do_not_depend_on_xdg_environment(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            self.assertEqual(pathlib.Path(root) / "state", manager.state_dir)
            self.assertEqual(
                pathlib.Path(root) / "runtime" / "voom-agent-vault",
                manager.runtime_dir,
            )

    def test_attachment_identity_fields_are_not_mutable(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "E" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            attachment["agentName"] = "another-agent"
            MODULE.atomic_json(manager.attachment_path(vm_id), attachment)
            with self.assertRaisesRegex(
                MODULE.ManagerError, "invalid attachment record"
            ):
                manager.load_attachment(vm_id)

    def test_hold_files_are_separate_from_attachment_updates(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "A" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            request_id = manager.create_hold(vm_id, "test")
            attachment["pendingOperation"] = None
            manager.save_attachment(attachment)
            holds = manager.holds(vm_id)
            self.assertEqual([request_id], [hold["requestID"] for hold in holds])
            self.assertEqual("pending", holds[0]["state"])

    def test_confirming_absent_egress_activates_pending_hold(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "C" * 32
            manager.create_hold(vm_id, "test")
            manager.vm_info = lambda name: {
                "vm": {"id": vm_id, "network": {"egress": None}}
            }
            self.assertTrue(manager.ensure_disabled("test-vm", vm_id))
            holds = manager.holds(vm_id)
            self.assertEqual("active", holds[0]["state"])

    def test_hold_created_during_enable_is_disabled_afterward(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "D" * 32
            enabled = {"value": False}

            def voom_egress(action, name, expected_id, *arguments):
                self.assertEqual(vm_id, expected_id)
                if action == "enable":
                    enabled["value"] = True
                    manager.create_hold(vm_id, "raced")
                elif action == "disable":
                    enabled["value"] = False
                return {}

            manager.voom_egress = voom_egress
            manager.vm_info = lambda name: {
                "vm": {
                    "id": vm_id,
                    "network": {
                        "egress": {"mode": "explicit", "enabled": enabled["value"]}
                    },
                }
            }
            with self.assertRaisesRegex(
                MODULE.ManagerError, "concurrent emergency hold"
            ):
                manager.enable_voom_with_hold_checks("test-vm", vm_id)
            self.assertFalse(enabled["value"])
            self.assertEqual("active", manager.holds(vm_id)[0]["state"])

    def test_command_timeout_kills_and_reaps_process(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            self.assertEqual(60, manager.timeout)
            started = time.monotonic()
            with self.assertRaisesRegex(MODULE.ManagerError, "timed out"):
                manager.run(
                    [sys.executable, "-c", "import time; time.sleep(10)"],
                    timeout=0.05,
                )
            self.assertLess(time.monotonic() - started, 1)

    def test_socket_verification_retries_until_listener_is_ready(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            socket_path = pathlib.Path(root) / "delayed.sock"
            accepted = threading.Event()

            def serve():
                time.sleep(0.1)
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    listener.bind(str(socket_path))
                    listener.listen()
                    connection, _ = listener.accept()
                    connection.close()
                    accepted.set()
                finally:
                    listener.close()

            server = threading.Thread(target=serve, daemon=True)
            server.start()
            manager.verify_socket(
                {"socket": str(socket_path), "lastKnownName": "test"}, timeout=2
            )
            server.join(timeout=2)
            self.assertTrue(accepted.is_set())

    def test_sync_continues_after_one_vm_fails(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            manager.assignments = {"broken": "personal", "healthy": "work"}
            manager.list_vms = lambda: {
                "broken": {"id": "9" * 32, "name": "broken"},
                "healthy": {"id": "A" * 32, "name": "healthy"},
            }
            visited = []

            def reconcile(name, profile, row):
                visited.append(name)
                if name == "broken":
                    raise MODULE.ManagerError("forced failure")

            manager.reconcile_attachment = reconcile
            manager.all_attachments = dict
            with (
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaisesRegex(MODULE.ManagerError, "incomplete"),
            ):
                manager.sync()
            self.assertEqual(["broken", "healthy"], visited)

    def test_missing_assigned_vm_is_pending_not_failure(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            manager.assignments = {"not-created": "personal"}
            manager.list_vms = dict
            manager.all_attachments = dict
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                manager.sync()
            self.assertIn("pending; VM does not exist", output.getvalue())

    def test_new_attachment_is_set_disabled_before_enable(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "1" * 32
            state = self.simulated_voom(manager, vm_id)
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            attachment = manager.load_attachment(vm_id)
            self.assertTrue(state["declaration"]["enabled"])
            self.assertTrue(attachment["desiredEnabled"])
            self.assertIsNone(attachment["pendingOperation"])

    def test_hold_keeps_new_attachment_disabled(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "2" * 32
            state = self.simulated_voom(manager, vm_id)
            manager.create_hold(vm_id, "test")
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            self.assertFalse(state["declaration"]["enabled"])
            self.assertEqual("active", manager.holds(vm_id)[0]["state"])

    def test_sync_adopts_manual_disable_and_reverses_raw_enable(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "3" * 32
            state = self.simulated_voom(manager, vm_id)
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            state["declaration"]["enabled"] = False
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            self.assertFalse(manager.load_attachment(vm_id)["desiredEnabled"])
            state["declaration"]["enabled"] = True
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            self.assertFalse(state["declaration"]["enabled"])

    def test_pending_attach_with_exact_declaration_resumes_while_running(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "4" * 32
            state = self.simulated_voom(manager, vm_id)
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            attachment = manager.load_attachment(vm_id)
            attachment["pendingOperation"] = {
                "kind": "attach",
                "phase": "voom-set",
                "restoreEnabled": True,
            }
            manager.save_attachment(attachment)
            state["running"] = True
            state["declaration"]["enabled"] = False
            manager.reconcile_attachment("test", "personal", {"id": vm_id})
            self.assertTrue(state["declaration"]["enabled"])
            self.assertIsNone(manager.load_attachment(vm_id)["pendingOperation"])

    def test_all_recorded_attach_phases_resume(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        for index, phase in enumerate(
            ("created", "agent", "bridge", "voom-set", "enable")
        ):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                manager = TestManager(root, haproxy)
                vm_id = f"{index + 10:032X}"
                attachment = manager.new_attachment("test", vm_id, "personal")
                attachment["pendingOperation"] = {
                    "kind": "attach",
                    "phase": phase,
                    "restoreEnabled": True,
                }
                manager.save_attachment(attachment)
                state = self.simulated_voom(
                    manager,
                    vm_id,
                    running=True,
                    declaration={
                        "mode": "explicit",
                        "backendSocket": attachment["socket"],
                        "caCertPath": str(manager.ca_path),
                        "enabled": False,
                    },
                )
                manager.reconcile_attachment("test", "personal", {"id": vm_id})
                self.assertTrue(state["declaration"]["enabled"])
                self.assertIsNone(manager.load_attachment(vm_id)["pendingOperation"])

    def test_all_recorded_rotate_phases_recover_a_rejected_token(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        for index, phase in enumerate(("disable", "token", "bridge")):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                manager = TestManager(root, haproxy)
                vm_id = f"{index + 40:032X}"
                attachment = manager.new_attachment("test", vm_id, "personal")
                attachment["pendingOperation"] = {
                    "kind": "rotate",
                    "phase": phase,
                    "restoreEnabled": True,
                }
                manager.save_attachment(attachment)
                manager.write_token(vm_id, "revoked-token")
                state = self.simulated_voom(
                    manager,
                    vm_id,
                    declaration={
                        "mode": "explicit",
                        "backendSocket": attachment["socket"],
                        "caCertPath": str(manager.ca_path),
                        "enabled": False,
                    },
                )
                manager.ensure_agent = lambda current: None
                rotations = []

                def verify_token(current, test_manager=manager, test_vm_id=vm_id):
                    if test_manager.read_token(test_vm_id) != "replacement-token":
                        raise MODULE.HTTPError(401, "invalid token")

                def rotate_agent(agent_name, calls=rotations):
                    calls.append(agent_name)
                    return "replacement-token"

                manager.verify_token = verify_token
                manager.rotate_agent = rotate_agent
                manager.reconcile_attachment("test", "personal", {"id": vm_id})
                self.assertEqual([attachment["agentName"]], rotations)
                self.assertEqual("replacement-token", manager.read_token(vm_id))
                self.assertTrue(state["declaration"]["enabled"])
                self.assertIsNone(manager.load_attachment(vm_id)["pendingOperation"])

    def test_all_recorded_profile_change_phases_resume(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        for index, phase in enumerate(("disable", "grants", "bridge")):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                manager = TestManager(root, haproxy)
                vm_id = f"{index + 20:032X}"
                attachment = manager.new_attachment("test", vm_id, "old")
                attachment["pendingOperation"] = {
                    "kind": "profile-change",
                    "phase": phase,
                    "restoreEnabled": True,
                    "sourceProfile": "old",
                    "targetProfile": "new",
                }
                manager.save_attachment(attachment)
                manager.write_token(vm_id, "old-token")
                state = self.simulated_voom(
                    manager,
                    vm_id,
                    running=True,
                    declaration={
                        "mode": "explicit",
                        "backendSocket": attachment["socket"],
                        "caCertPath": str(manager.ca_path),
                        "enabled": False,
                    },
                )
                manager.require_admin = lambda: None
                manager.vault_exists = lambda vault: True
                manager.remove_grant = lambda agent, vault: None
                manager.get_agent = lambda agent: {"vaults": []}
                manager.add_grant = lambda agent, vault: None
                manager.rotate_agent = lambda agent: "new-token"
                manager.reconcile_attachment("test", "new", {"id": vm_id})
                applied = manager.load_attachment(vm_id)
                self.assertEqual("new", applied["profile"])
                self.assertEqual("new-token", manager.read_token(vm_id))
                self.assertIsNone(applied["pendingOperation"])
                self.assertTrue(state["declaration"]["enabled"])

    def test_all_recorded_detach_phases_resume(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        for index, phase in enumerate(("disable", "revoke")):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                manager = TestManager(root, haproxy)
                vm_id = f"{index + 30:032X}"
                attachment = manager.new_attachment("test", vm_id, "personal")
                attachment["desiredEnabled"] = False
                attachment["pendingOperation"] = {
                    "kind": "detach",
                    "phase": phase,
                    "restoreEnabled": False,
                }
                manager.save_attachment(attachment)
                manager.write_token(vm_id, "old-token")
                state = self.simulated_voom(
                    manager,
                    vm_id,
                    declaration={
                        "mode": "explicit",
                        "backendSocket": attachment["socket"],
                        "caCertPath": str(manager.ca_path),
                        "enabled": False,
                    },
                )
                manager.require_admin = lambda: None
                manager.revoke_agent = lambda agent: None
                manager.detach_one("test", vm_id, attachment)
                self.assertIsNone(manager.load_attachment(vm_id))
                self.assertFalse(manager.token_path(vm_id).exists())
                self.assertIsNone(state["declaration"])

    def test_renderer_keeps_tokens_out_of_main_config(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "B" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            manager.write_token(vm_id, "av_agent_secret")
            self.assertEqual(1, manager.render_bridge())
            active = manager.runtime_dir / "current"
            config = (active / "haproxy.cfg").read_text()
            token_map = (active / "tokens.map").read_text()
            self.assertNotIn("av_agent_secret", config)
            self.assertNotIn("personal", config)
            self.assertIn("http-reuse never", config)
            self.assertIn("deny_status 403 if !{ var(txn.av_auth) -m found }", config)
            self.assertIn("YXZfYWdlbnRfc2VjcmV0OnBlcnNvbmFs", token_map)
            self.assertEqual(
                0o600, stat.S_IMODE((active / "tokens.map").stat().st_mode)
            )

    def test_empty_renderer_produces_a_valid_fail_closed_listener(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            self.assertEqual(0, manager.render_bridge())
            config = (manager.runtime_dir / "current" / "haproxy.cfg").read_text()
            self.assertIn("frontend no_attachments", config)
            self.assertIn("deny_status 503", config)

    def test_reload_failure_restores_previous_bridge_generation(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "7" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            manager.write_token(vm_id, "first-token")
            manager.render_bridge()
            active = manager.runtime_dir / "current"
            previous = os.readlink(active)
            manager.write_token(vm_id, "second-token")
            calls = []

            def reload_bridge():
                calls.append(True)
                if len(calls) == 1:
                    raise MODULE.ManagerError("reload failed")

            manager.reload_bridge = reload_bridge
            with self.assertRaisesRegex(MODULE.ManagerError, "reload failed"):
                manager.render_and_reload_bridge()
            self.assertEqual(previous, os.readlink(active))
            self.assertEqual(2, len(calls))
            self.assertEqual(
                [pathlib.Path(previous).name],
                [path.name for path in (manager.runtime_dir / "generations").iterdir()],
            )

    def test_successful_reload_prunes_old_bridge_generations(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "A" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            manager.write_token(vm_id, "old-token")
            manager.render_bridge()
            old_generation = os.readlink(manager.runtime_dir / "current")
            manager.write_token(vm_id, "new-token")
            manager.reload_bridge = lambda: None
            manager.render_and_reload_bridge()
            current_generation = os.readlink(manager.runtime_dir / "current")
            self.assertNotEqual(old_generation, current_generation)
            self.assertEqual(
                [pathlib.Path(current_generation).name],
                [path.name for path in (manager.runtime_dir / "generations").iterdir()],
            )

    def test_enable_rejects_a_different_voom_declaration(self):
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, "/bin/true")
            vm_id = "D" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            attachment["pendingOperation"] = None
            manager.save_attachment(attachment)
            manager.list_vms = lambda: {"test": {"id": vm_id, "name": "test"}}
            manager.vm_info = lambda name: {
                "vm": {
                    "id": vm_id,
                    "network": {
                        "egress": {
                            "mode": "explicit",
                            "backendSocket": "/run/wrong.sock",
                            "caCertPath": str(manager.ca_path),
                            "enabled": False,
                        }
                    },
                }
            }
            with self.assertRaisesRegex(MODULE.ManagerError, "does not match"):
                manager.enable("test")

    def test_status_rejects_runtime_drift(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "8" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            attachment["pendingOperation"] = None
            manager.save_attachment(attachment)
            manager.write_token(vm_id, "token")
            manager.assignments = {"test": "personal"}
            manager.render_bridge()
            manager.list_vms = lambda: {
                "test": {"id": vm_id, "name": "test", "status": "running"}
            }
            manager.vm_info = lambda name: {
                "running": True,
                "vm": {
                    "id": vm_id,
                    "network": {
                        "egress": {
                            "mode": "explicit",
                            "backendSocket": attachment["socket"],
                            "caCertPath": str(manager.ca_path),
                            "enabled": True,
                        }
                    },
                },
                "egressRuntime": {
                    "inSync": False,
                    "caPresent": True,
                    "error": "stale manifest",
                },
            }
            manager.ca_path.write_text("public CA")
            manager._probe_management = lambda: True
            manager._probe_tcp = lambda address: True
            manager._unit_active = lambda unit, user=False: True
            manager.firewall_status = pathlib.Path(root) / "firewall.json"
            MODULE.atomic_json(
                manager.firewall_status,
                {"schemaVersion": 1, "ok": True, "timestamp": int(time.time())},
            )
            output = io.StringIO()
            with (
                contextlib.redirect_stdout(output),
                self.assertRaisesRegex(MODULE.ManagerError, "status found"),
            ):
                manager.status(as_json=True)
            result = json.loads(output.getvalue())
            self.assertFalse(result["attachments"][0]["caConsistent"])
            self.assertTrue(
                any("runtime is out of sync" in error for error in result["errors"])
            )

    def test_missing_map_entry_is_denied_without_backend(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            vm_id = "F" * 32
            attachment = manager.new_attachment("test", vm_id, "personal")
            manager.save_attachment(attachment)
            manager.write_token(vm_id, "av_agent_secret")
            manager.render_bridge()
            active = manager.runtime_dir / "current"
            (active / "tokens.map").write_text("")
            process = subprocess.Popen(
                [haproxy, "-db", "-f", str(active / "haproxy.cfg")],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                socket_path = pathlib.Path(attachment["socket"])
                for _ in range(100):
                    if socket_path.is_socket():
                        break
                    if process.poll() is not None:
                        _, stderr = process.communicate()
                        self.fail(f"HAProxy exited before binding: {stderr.decode()}")
                    time.sleep(0.01)
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(2)
                try:
                    client.connect(str(socket_path))
                    client.sendall(
                        b"GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"
                    )
                    response = client.recv(4096)
                finally:
                    client.close()
                self.assertIn(b" 403 ", response.splitlines()[0])
            finally:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)

    def test_frontends_replace_guest_auth_and_use_separate_backend_connections(self):
        haproxy = os.environ.get("HAPROXY")
        if not haproxy:
            self.skipTest("HAPROXY is not set")
        with tempfile.TemporaryDirectory() as root:
            manager = TestManager(root, haproxy)
            backend = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            backend.bind(("127.0.0.1", 0))
            backend.listen()
            manager.proxy_address = f"127.0.0.1:{backend.getsockname()[1]}"
            requests = []

            def serve():
                for _ in range(2):
                    connection, _ = backend.accept()
                    with connection:
                        data = b""
                        while b"\r\n\r\n" not in data:
                            data += connection.recv(4096)
                        requests.append(data)
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        )

            server = threading.Thread(target=serve, daemon=True)
            server.start()
            attachments = []
            for vm_id, profile, token in (
                ("5" * 32, "personal", "token-personal"),
                ("6" * 32, "work", "token-work"),
            ):
                attachment = manager.new_attachment(profile, vm_id, profile)
                manager.save_attachment(attachment)
                manager.write_token(vm_id, token)
                attachments.append(attachment)
            manager.render_bridge()
            active = manager.runtime_dir / "current"
            process = subprocess.Popen(
                [haproxy, "-db", "-f", str(active / "haproxy.cfg")],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                for attachment in attachments:
                    socket_path = pathlib.Path(attachment["socket"])
                    for _ in range(100):
                        if socket_path.is_socket():
                            break
                        if process.poll() is not None:
                            _, stderr = process.communicate()
                            self.fail(
                                f"HAProxy exited before binding: {stderr.decode()}"
                            )
                        time.sleep(0.01)
                    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    client.settimeout(2)
                    with client:
                        client.connect(str(socket_path))
                        client.sendall(
                            b"GET http://example.com/ HTTP/1.1\r\n"
                            b"Host: example.com\r\n"
                            b"Proxy-Authorization: Basic attacker\r\n\r\n"
                        )
                        response = client.recv(4096)
                    self.assertIn(b" 200 ", response.splitlines()[0])
            finally:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)
                backend.close()
                server.join(timeout=5)
            self.assertFalse(server.is_alive())
            self.assertEqual(2, len(requests))
            expected = {
                b"Basic " + MODULE.base64.b64encode(b"token-personal:personal"),
                b"Basic " + MODULE.base64.b64encode(b"token-work:work"),
            }
            observed = {
                line.split(b":", 1)[1].strip()
                for request in requests
                for line in request.split(b"\r\n")
                if line.lower().startswith(b"proxy-authorization:")
            }
            self.assertEqual(expected, observed)


if __name__ == "__main__":
    unittest.main()
