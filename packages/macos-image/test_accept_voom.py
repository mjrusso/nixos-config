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


class AcceptanceTests(unittest.TestCase):
    def package(self, root):
        package = root / "package"
        package.mkdir()
        body = '''import json, os, pathlib, signal, sys, time
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
    print(json.dumps({'checks':[{'name':'ssh-and-architecture','ok':ready}]}))
    sys.exit(0 if ready else 1)
elif args[0] == 'info': print('{"vm":{"id":"ready"}}')
elif args[0] == 'version': print('voom test')
elif args[:2] == ['image', 'import']: (state / 'image').touch()
elif args[:2] == ['image', 'inspect']: print('{}')
elif args[0] == 'create':
    (state / 'vm').touch()
    if (package / 'interrupt-create').exists():
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(60)
    sys.exit(1)
elif args[0] == 'list': print(json.dumps([{'name':'acceptance-vm'}] if (state / 'vm').exists() else []))
elif args[0] == 'stop':
    if (package / 'refuse-stop').exists(): sys.exit(1)
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
            helper.write_text(f"#!{sys.executable}\nimport json\nprint(json.dumps({{'gui-lifecycle-v1': 1, 'virtiofs-readonly-v1': 1, 'guest-isolation-v1': 1}}))\n")
            helper.chmod(0o755)
        return binary

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
            helpers = json.loads((acceptance.evidence / "helpers.json").read_text())
            self.assertEqual(helpers["vfkit"]["capabilities"]["virtiofs-readonly-v1"], 1)
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
                (bundle / "image.json").write_text(json.dumps({"capabilities": {"controlShare": True, "guestShareMount": True, "guestPortReport": True}}))
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
