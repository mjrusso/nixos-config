import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

import accept_voom


CAPABILITIES = {"metadataDisk": False, "controlShare": False, "guestPortReport": False, "guestShareMount": False, "nixosSwitch": False}


class AcceptanceTests(unittest.TestCase):
    def package(self, root):
        package = root / "package"
        package.mkdir()
        body = '''import json, os, pathlib, shlex, signal, sys, time
package = pathlib.Path(__file__).parent
state = pathlib.Path(os.environ['VOOM_STATE_DIR'])
state.mkdir(parents=True, exist_ok=True)
args = sys.argv[1:]
if '--output' in args:
    position = args.index('--output')
    del args[position:position+2]
with (state / 'commands.jsonl').open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args == ['debug', 'helpers']:
    print(json.dumps({name: str(package / name) for name in ('voom', 'vfkit', 'gvproxy', 'voom-macos-identity')}))
elif args == ['debug', 'paths']:
    print(json.dumps({name: os.environ['VOOM_' + name.upper() + '_DIR'] for name in ('config','state','cache','runtime')}))
elif args[0] == 'doctor': print('[]')
elif args[:2] == ['guest', 'verify']:
    ready = (state / 'checked').exists()
    (state / 'checked').touch()
    if (package / 'missing-system').exists():
        print(json.dumps({'checks':[{'name':'ssh-and-architecture','ok':True}, {'name':'active-system','ok':False}]}))
        sys.exit(1)
    print(json.dumps({'checks':[{'name':'ssh-and-architecture','ok':ready}]}))
    sys.exit(0 if ready else 1)
elif args[0] == 'info':
    identity = 'b' if (package / 'change-identity').exists() and int((state / 'boots').read_text()) > 1 else 'a'
    print(json.dumps({'vm': {'id': 'ready', 'macos': {'identitySha256': identity * 64}}}))
elif args[0] == 'version': print('voom test')
elif args[:2] == ['image', 'import']: (state / 'image').touch()
elif args[:2] == ['image', 'inspect']: print('{}')
elif args[0] == 'create':
    (state / 'vm').touch()
    if (package / 'interrupt-create').exists():
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(60)
    sys.exit(0 if (package / 'successful-create').exists() else 1)
elif args[0] == 'start':
    (state / 'running').touch()
    boots = int((state / 'boots').read_text()) if (state / 'boots').exists() else 0
    (state / 'boots').write_text(str(boots + 1))
    if boots and (package / 'lose-marker').exists(): (state / 'marker').unlink()
elif args[0] == 'list': print(json.dumps([{'name':'acceptance-vm', 'status':'running' if (state / 'running').exists() else 'stopped'}] if (state / 'vm').exists() else []))
elif args[0] == 'ssh':
    script = shlex.split(args[-1])[-1]
    if 'printf' in script and 'voom-accept-marker' in script:
        (state / 'marker').write_text(shlex.split(script)[-3])
    elif 'voom-accept-marker' in script:
        if not (state / 'marker').exists() or (state / 'marker').read_text() != shlex.split(script)[-1]: sys.exit(1)
    print('Darwin guest diagnostics', flush=True)
    if (package / 'refuse-diagnostics').exists(): sys.exit(255)
    if (package / 'hang-diagnostics').exists(): time.sleep(60)
elif args[0] == 'stop':
    if (package / 'refuse-stop').exists(): sys.exit(1)
    (state / 'running').unlink(missing_ok=True)
elif args[0] == 'remove': (state / 'vm').unlink()
elif args[:2] == ['image', 'list']: print(json.dumps([{'name':'acceptance-image'}] if (state / 'image').exists() else []))
elif args[:2] == ['image', 'remove']: (state / 'image').unlink()
elif args[0] != 'logs': raise RuntimeError(args)
'''
        binary = package / "voom"
        binary.write_text(f"#!{sys.executable}\n" + body)
        binary.chmod(0o755)
        for name in accept_voom.HELPERS:
            helper = package / name
            helper.write_text(f"#!{sys.executable}\nimport json\nprint(json.dumps({{'gui-lifecycle-v1': 1, 'guest-isolation-v1': 1}}))\n")
            helper.chmod(0o755)
        return binary.resolve()

    def fixture(self, root, capabilities=None):
        binary = self.package(root)
        bundle = root / "bundle"
        bundle.mkdir()
        for name in ("image.json", "restore.json", "toolchain.json", "HardwareModel", "MachineIdentifier", "AuxiliaryStorage", "disk.raw"):
            (bundle / name).write_text("golden")
        (bundle / "image.json").write_text(json.dumps({"capabilities": CAPABILITIES if capabilities is None else capabilities}))
        key = root / "key"
        key.write_text("private test identity")
        work = root / "work"
        work.mkdir()
        return accept_voom.Acceptance(binary, bundle, key, work, 10)

    def test_restart_checks_persistence_and_identity_without_shares_or_forwarding(self):
        for failure in (None, "lose-marker", "change-identity"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(dir="/tmp") as directory:
                acceptance = self.fixture(Path(directory))
                (acceptance.voom.parent / "successful-create").touch()
                if failure:
                    (acceptance.voom.parent / failure).touch()
                before = accept_voom.fingerprint_bundle(acceptance.bundle)
                with patch.object(accept_voom.time, "sleep"), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    status = accept_voom.execute(acceptance)
                self.assertEqual(status, 0 if failure is None else 1)
                self.assertEqual(accept_voom.fingerprint_bundle(acceptance.bundle), before)
                commands = [json.loads(line) for line in (acceptance.root / "state/commands.jsonl").read_text().splitlines()]
                self.assertFalse(any(command[0] in ("share", "forward", "egress") for command in commands))
                self.assertFalse((acceptance.root / "state/vm").exists())
                self.assertFalse((acceptance.root / "state/image").exists())
                if failure is None:
                    self.assertEqual(commands.count(["start", accept_voom.VM]), 2)
                    self.assertEqual(commands.count(["stop", accept_voom.VM]), 2)
                    self.assertTrue((acceptance.evidence / "restart-guest.json").is_file())
                if failure == "change-identity":
                    self.assertIn("Apple identity changed", json.loads((acceptance.evidence / "result.json").read_text())["error"])

    def test_unsupported_or_malformed_capabilities_are_rejected_before_import(self):
        invalid = [{}, [], {name: 0 for name in CAPABILITIES}]
        invalid += [{**CAPABILITIES, name: True} for name in CAPABILITIES]
        for capabilities in invalid:
            with self.subTest(capabilities=capabilities), tempfile.TemporaryDirectory(dir="/tmp") as directory:
                acceptance = self.fixture(Path(directory), capabilities)
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(accept_voom.execute(acceptance), 1)
                result = json.loads((acceptance.evidence / "result.json").read_text())
                self.assertIn("re-bake", result["error"])
                commands = [json.loads(line) for line in (acceptance.root / "state/commands.jsonl").read_text().splitlines()]
                self.assertNotIn(["image", "import"], [command[:2] for command in commands])

    def test_configuration_requires_a_resolving_active_system_symlink(self):
        for mode in ("missing", "directory", "dangling", "active"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                acceptance = accept_voom.Acceptance(root, root, root, root, 10)
                active = root / "current-system"
                if mode == "directory":
                    active.mkdir()
                elif mode in ("dangling", "active"):
                    target = root / "system"
                    if mode == "active":
                        target.mkdir()
                    active.symlink_to(target)
                reached_nix = root / "reached-nix"
                nix = root / "nix"
                nix.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(reached_nix)!r}).touch()\n")
                nix.chmod(0o755)

                def ssh(script):
                    script = script.replace("/run/current-system", str(active))
                    script = script.replace("/nix/var/nix/profiles/default/bin/nix", str(nix))
                    script = script.replace("/Library/LaunchDaemons/org.voom.guest-services.plist", str(root / "service.plist"))
                    return subprocess.run(["/bin/sh", "-c", 'set -eu\nsudo() { test "$*" = "-n true"; }\n' + script], check=True)

                with patch.object(acceptance, "ssh", side_effect=ssh):
                    if mode == "active":
                        acceptance.verify_configuration()
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            acceptance.verify_configuration()
                self.assertEqual(reached_nix.exists(), mode == "active")

    def test_environment_is_isolated_and_clears_all_helper_overrides(self):
        original = {"VOOM_VFKIT": "/bad/vfkit", "VOOM_GVPROXY": "/bad/gvproxy", "VOOM_MACOS_IDENTITY": "/bad/identity", "VOOM_STATE_DIR": "/real/state", "SSH_AUTH_SOCK": "/agent"}
        with patch.dict(os.environ, original, clear=True):
            env = accept_voom.acceptance_environment(Path("/test"))
            self.assertEqual(dict(os.environ), original)
        for name in ("VOOM_VFKIT", "VOOM_GVPROXY", "VOOM_MACOS_IDENTITY"):
            self.assertNotIn(name, env)
        self.assertEqual(env["VOOM_STATE_DIR"], "/test/state")
        self.assertEqual(env["SSH_AUTH_SOCK"], "/agent")

    def test_package_helpers_are_verified_and_missing_bundle_cannot_fall_back(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            binary = self.package(root)
            work = root / "work"
            work.mkdir()
            acceptance = accept_voom.Acceptance(binary, root, root, work, 10)
            acceptance.check_helpers()
            (binary.parent / "vfkit").unlink()
            with self.assertRaisesRegex(RuntimeError, "not resolved from the selected Voom package"):
                acceptance.check_helpers()

    def test_failure_after_registration_cleans_only_disposable_objects(self):
        for mode in ("create-failure", "stop-failure", "interruption"):
            refuse_stop = mode == "stop-failure"
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                binary = self.package(root)
                if refuse_stop:
                    (binary.parent / "refuse-stop").touch()
                if mode == "interruption":
                    (binary.parent / "interrupt-create").touch()
                bundle = root / "bundle"
                bundle.mkdir()
                for name in ("image.json", "restore.json", "toolchain.json", "HardwareModel", "MachineIdentifier", "AuxiliaryStorage", "disk.raw"):
                    (bundle / name).write_text("golden")
                (bundle / "image.json").write_text(json.dumps({"capabilities": CAPABILITIES}))
                before = accept_voom.fingerprint_bundle(bundle)
                key = root / "key"
                key.write_text("private test identity")
                work = root / "work"
                args = ["verify-macos-voom", "--voom", str(binary), "--bundle", str(bundle), "--identity", str(key), "--work-dir", str(work)]
                with patch.object(sys, "argv", args), patch.object(accept_voom.platform, "system", return_value="Darwin"), patch.object(accept_voom.platform, "machine", return_value="arm64"), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    status = accept_voom.main()
                self.assertEqual(status, 1)
                self.assertEqual(accept_voom.fingerprint_bundle(bundle), before)
                self.assertEqual((work / "state/vm").exists(), refuse_stop)
                self.assertEqual((work / "state/image").exists(), refuse_stop)
                result = json.loads((work / "evidence/result.json").read_text())
                self.assertFalse(result["passed"])
                if refuse_stop:
                    self.assertIn("cleanup failed", result["error"])
                if mode == "interruption":
                    self.assertIn("Received signal", result["error"])
                self.assertTrue(list((work / "evidence").glob("*.stderr")))

    def test_guest_readiness_retries_failed_ssh_and_preserves_reports(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            binary = self.package(root)
            work = root / "work"
            work.mkdir()
            acceptance = accept_voom.Acceptance(binary, root, root, work, 10)
            with patch.object(accept_voom.time, "sleep"):
                result = acceptance.verify_guest("boot")
            self.assertEqual(result["vm"]["id"], "ready")
            attempts = list(acceptance.evidence.glob("*-guest.stdout"))
            self.assertEqual(len(attempts), 2)
            self.assertTrue((acceptance.evidence / "boot-guest.json").is_file())

    def test_guest_timeout_names_failed_checks_and_keeps_last_report(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            binary = self.package(root)
            (binary.parent / "missing-system").touch()
            acceptance = accept_voom.Acceptance(binary, root, root, root, 10)
            with patch.object(accept_voom.time, "monotonic", side_effect=[0, 0, 11]), patch.object(accept_voom.time, "sleep"):
                with self.assertRaisesRegex(TimeoutError, "active-system") as failure:
                    acceptance.verify_guest("boot")
            self.assertNotIn("waiting for SSH", str(failure.exception))
            report = json.loads((acceptance.evidence / "boot-guest.json").read_text())
            self.assertTrue(report["checks"][0]["ok"])
            self.assertFalse(report["checks"][1]["ok"])

    def test_guest_diagnostics_precede_stop_and_failure_does_not_prevent_cleanup(self):
        for mode in ("success", "refuse-diagnostics", "hang-diagnostics"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                binary = self.package(root)
                if mode != "success":
                    (binary.parent / mode).touch()
                acceptance = accept_voom.Acceptance(binary, root, root, root, 1)
                state = root / "state"
                state.mkdir()
                for name in ("vm", "image", "running"):
                    (state / name).touch()
                acceptance.cleanup()
                commands = [json.loads(line) for line in (state / "commands.jsonl").read_text().splitlines()]
                ssh = next(command for command in commands if command[0] == "ssh")
                self.assertLess(commands.index(ssh), commands.index(["stop", accept_voom.VM]))
                self.assertIn("Darwin guest diagnostics", next(acceptance.evidence.glob("*-ssh.stdout")).read_text())
                self.assertFalse((state / "vm").exists())
                self.assertFalse((state / "image").exists())

    def test_existing_work_directory_is_rejected_without_running_voom(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            binary = self.package(root)
            key = root / "key"
            key.write_text("private test identity")
            bundle = root / "bundle"
            bundle.mkdir()
            work = root / "existing"
            work.mkdir()
            sentinel = work / "keep"
            sentinel.write_text("existing data")
            args = ["verify-macos-voom", "--voom", str(binary), "--bundle", str(bundle), "--identity", str(key), "--work-dir", str(work)]
            with patch.object(sys, "argv", args), patch.object(accept_voom.platform, "system", return_value="Darwin"), patch.object(accept_voom.platform, "machine", return_value="arm64"), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                accept_voom.main()
            self.assertEqual(sentinel.read_text(), "existing data")
            self.assertFalse((work / "state").exists())

    def test_command_timeout_preserves_evidence(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            binary = root / "voom"
            binary.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(60)\n")
            binary.chmod(0o755)
            acceptance = accept_voom.Acceptance(binary, root, root, root, 1)
            with self.assertRaises(subprocess.TimeoutExpired):
                acceptance.command("version", timeout=0.05)
            self.assertTrue((acceptance.evidence / "001-version.command.json").is_file())
