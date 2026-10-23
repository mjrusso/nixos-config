import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "voom-update"
SYSTEM = "/nix/store/00000000000000000000000000000000-darwin-system-test"
STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
entry = {"command": command, "args": args}
if command == "voom" and args[0] == "ssh" and "-s" in args:
    entry["stdin"] = sys.stdin.read()
if command == "nix" and args[0] == "copy":
    config = os.environ["NIX_SSHOPTS"].removeprefix("-F ")
    entry["configPath"] = config
    entry["config"] = Path(config).read_text()
with open(os.environ["UPDATE_LOG"], "a") as stream:
    stream.write(json.dumps(entry) + "\n")
data = json.loads(Path(os.environ["UPDATE_FIXTURE"]).read_text())
if command == "nix":
    if args[0] == os.environ.get("FAIL_NIX"):
        sys.exit(3)
    if args[0] == "build":
        system = data["system"]
        Path(args[args.index("--out-link") + 1]).symlink_to(system)
        print(system)
    sys.exit(0)
if args[0] == "list":
    if os.environ.get("FAIL_LIST"):
        sys.exit(4)
    print(json.dumps([{"name": name} for name in data["vms"]]))
elif args[0] == "info":
    if args[1] not in data["vms"]:
        sys.exit(1)
    print(json.dumps(data["vms"][args[1]]))
elif args[:2] == ["image", "inspect"]:
    print(json.dumps(data["images"][args[2]]))
elif args[0] == "ssh-config":
    print("Host voom-" + args[1] + '\n  IdentityFile "/keys/key with spaces"')
elif args[0] == "ssh" and os.environ.get("FAIL_ACTIVATE") and "sudo" in args and "-s" in args:
    sys.exit(5)
'''


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.flake = self.root / "private flake"
        self.flake.mkdir()
        (self.flake / "flake.nix").write_text("{}")
        platform = self.root / "platform state"
        platform.mkdir()
        (platform / "bundle.json").write_text(json.dumps({"target": "aarch64-darwin@vm"}))
        self.platform = platform
        self.fixture = {"system": SYSTEM, "vms": {}, "images": {}}
        for name, arch, running, managed in (
            ("linux", "aarch64-linux", True, True),
            ("mac", "aarch64-darwin", True, True),
            ("stopped", "aarch64-darwin", False, True),
            ("other", "aarch64-linux", True, False),
        ):
            vm = {"arch": arch, "image": {"name": name, "id": name}, "name": name}
            image = {"id": name, "format": "raw", "capabilities": {"nixosSwitch": managed and arch.endswith("-linux")}}
            if arch.endswith("-darwin"):
                vm["macos"] = image["macos"] = {"identitySha256": "fixture"}
            self.fixture["vms"][name] = {"vm": vm, "running": running}
            self.fixture["images"][name] = {"image": image, "platformStateDir": str(platform)}
        self.log = self.root / "log"
        self.fixture_path = self.root / "fixture.json"
        commands = self.root / "bin"
        commands.mkdir()
        for command in ("voom", "nix"):
            path = commands / command
            path.write_text(STUB.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
            path.chmod(0o755)
        self.env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"], "UPDATE_LOG": str(self.log), "UPDATE_FIXTURE": str(self.fixture_path)}

    def run_update(self, *args, **environment):
        self.fixture_path.write_text(json.dumps(self.fixture))
        result = subprocess.run(["bash", str(SCRIPT), "--flake", str(self.flake), *args], env={**self.env, **environment}, text=True, capture_output=True, input="")
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result

    def test_default_updates_mixed_guests_and_copies_before_activation(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("updated: linux mac", result.stdout)
        self.assertIn("skipping stopped: not running", result.stdout)
        self.assertIn("skipping other: no applicable", result.stdout)
        nixos = [call for call in self.calls if call["args"][:2] == ["nixos", "switch"]]
        self.assertEqual([call["args"][2] for call in nixos], ["linux"])
        self.assertIn(str(self.flake) + "#vm-aarch64-linux-raw", nixos[0]["args"])
        build = next(call for call in self.calls if call["command"] == "nix" and call["args"][0] == "build")
        self.assertIn(str(self.flake) + '#darwinConfigurations."aarch64-darwin@vm".system', build["args"])
        copy = next(call for call in self.calls if call["command"] == "nix" and call["args"][0] == "copy")
        self.assertIn("--no-check-sigs", copy["args"])
        self.assertTrue(copy["args"][copy["args"].index("--to") + 1].startswith("ssh-ng://voom-mac?"))
        self.assertIn('IdentityFile "/keys/key with spaces"', copy["config"])
        activation = next(call for call in self.calls if "stdin" in call and "darwin-rebuild" in call["stdin"])
        self.assertLess(self.calls.index(copy), self.calls.index(activation))
        self.assertIn("--profile /nix/var/nix/profiles/system --set", activation["stdin"])
        self.assertIn('"$system/sw/bin/darwin-rebuild" activate', activation["stdin"])
        self.assertFalse(Path(copy["configPath"]).exists())
        emacs = [call["args"][1] for call in self.calls if "stdin" in call and ".emacs.d" in call["stdin"]]
        self.assertEqual(emacs, ["linux", "mac"])

    def test_dry_run_has_no_guest_or_build_mutations(self):
        result = self.run_update("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("darwin:", result.stdout)
        self.assertFalse(any(call["command"] == "nix" or call["args"][0] in ("ssh", "ssh-config", "nixos") for call in self.calls))

    def test_nixos_phase_skips_explicit_mac_guest(self):
        result = self.run_update("--nixos", "mac")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no applicable update phases", result.stdout)
        self.assertFalse(any(call["args"][0] in ("nixos", "ssh") for call in self.calls))

    def test_emacs_only_supports_mac_without_building(self):
        result = self.run_update("--emacs", "mac")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call["command"] == "nix" for call in self.calls))
        self.assertTrue(any("stdin" in call and ".emacs.d" in call["stdin"] for call in self.calls))

    def test_public_override_keeps_paths_with_spaces(self):
        public = self.root / "public flake"
        public.mkdir()
        result = self.run_update("--darwin", "--public-flake", str(public), "mac")
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in self.calls if call["command"] == "nix" and call["args"][0] == "build")
        self.assertIn("--no-write-lock-file", build["args"])
        self.assertEqual(build["args"][build["args"].index("--override-input") + 1:][:2], ["nixos-config", str(public)])

    def test_build_copy_and_activation_failures_are_reported(self):
        for failure in ("build", "copy", "activate"):
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                env = {"FAIL_ACTIVATE": "1"} if failure == "activate" else {"FAIL_NIX": failure}
                result = self.run_update("--darwin", "mac", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("mac(darwin)", result.stderr)
                if failure != "activate":
                    self.assertFalse(any("stdin" in call and "darwin-rebuild" in call["stdin"] for call in self.calls))
                build = next(call for call in self.calls if call["command"] == "nix" and call["args"][0] == "build")
                self.assertFalse(Path(build["args"][build["args"].index("--out-link") + 1]).parent.exists())

    def test_missing_target_fails_before_building(self):
        (self.platform / "bundle.json").write_text("{}")
        result = self.run_update("--darwin", "mac")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call["command"] == "nix" for call in self.calls))

    def test_discovery_failure_is_not_reported_as_no_vms(self):
        result = self.run_update(FAIL_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("No VMs to update", result.stdout)

    def test_empty_inventory(self):
        self.fixture["vms"] = {}
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No VMs to update", result.stdout)


if __name__ == "__main__":
    unittest.main()
