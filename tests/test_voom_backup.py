import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "voom-backup-macos"
MARKER = ".voom-backup-owned"
STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

command, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["BACKUP_LOG"], "a") as stream:
    stream.write(json.dumps({"command": command, "args": args}) + "\n")
if command == "mount":
    if not os.environ.get("MISSING_VOLUME"):
        print("/dev/disk9 on " + os.environ["VOOM_BACKUP_VOLUME"] + " (apfs, local)")
elif command == "voom":
    if os.environ.get("FAIL_VOOM"):
        sys.exit(1)
    if args[0] == "list":
        if os.environ.get("INVALID_LIST"):
            print("invalid JSON")
            sys.exit(0)
        if "VM_LIST" in os.environ:
            print(os.environ["VM_LIST"])
            sys.exit(0)
        print(json.dumps([{"name": name, "status": status, "sshPort": 2222 if name == "mac" else 2223} for name, status in
            [("mac", "running"), ("linux", "running"), ("stopped", "stopped"), ("second", "running")]]))
    else:
        name = args[1]
        if name == os.environ.get("FAIL_INFO"):
            sys.exit(1)
        print(json.dumps({"vm": {"arch": "aarch64-linux" if name == "linux" else "aarch64-darwin",
            "access": {"sshUser": "guest"}, "network": {"sshPort": 2222 if name == "mac" else 2223}}}))
elif command == "rsync":
    if os.environ.get("TEST_SSH_CONFIG"):
        ssh = shlex.split(args[args.index("-e") + 1])[1:]
        if "-F" not in ssh:
            ssh = ["-F", os.environ["TEST_SSH_CONFIG"], *ssh]
        result = subprocess.run([os.environ["TEST_SSH"], "-G", *ssh, "guest@127.0.0.1"],
                                capture_output=True, text=True)
        if result.returncode:
            sys.stderr.write(result.stderr)
            sys.exit(12)
        identities = [line.partition(" ")[2] for line in result.stdout.splitlines() if line.startswith("identityfile ")]
        expected_identity = os.environ.get("TEST_SSH_IDENTITY")
        if expected_identity is not None and identities != [expected_identity]:
            sys.exit("SSH used an unexpected identity")
    fail = "2222" in " ".join(args) and os.environ.get("RSYNC_FAIL_PATH", "") in args[-2]
    sys.exit(int(os.environ.get("RSYNC_EXIT", "0")) if fail else 0)
elif command.startswith("restic"):
    if args[0] == "backup" and "mac" in args:
        sys.exit(int(os.environ.get("RESTIC_EXIT", "0")))
'''


class BackupFixture(unittest.TestCase):
    script = SCRIPT

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="voom backup ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        commands = self.root / "bin"
        commands.mkdir()
        for command in ("mount", "voom", "rsync", "restic", "restic-backup-test"):
            path = commands / command
            path.write_text(STUB.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
            path.chmod(0o755)
        password = self.root / "password"
        identity = self.root / "key with spaces"
        password.touch()
        identity.touch()
        self.log = self.root / "log"
        self.stage = self.root / "stage"
        self.env = {
            **os.environ,
            "PATH": str(commands) + os.pathsep + os.environ["PATH"],
            "BACKUP_LOG": str(self.log),
            "RESTIC_REPOSITORY": str(self.root / "volume" / "repo"),
            "RESTIC_PASSWORD_FILE": str(password),
            "RESTIC_CACHE_DIR": str(self.root / "restic-cache"),
            "VOOM_BACKUP_VOLUME": str(self.root / "volume"),
            "VOOM_BACKUP_STAGE": str(self.stage),
            "VOOM_BACKUP_IDENTITY": str(identity),
            "CACHE_DIRECTORY": str(self.stage),
        }

    def run_backup(self, **environment):
        result = subprocess.run(["bash", str(self.script)], env={**self.env, **environment},
                                capture_output=True, text=True)
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result

    def snapshots(self):
        return [call["args"] for call in self.calls
                if call["command"].startswith("restic") and call["args"][0] == "backup"]


class BackupTests(BackupFixture):

    def test_only_running_macos_guests_are_saved_with_separate_identities(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshots = self.snapshots()
        self.assertEqual([args[args.index("--host") + 1] for args in snapshots], ["mac", "second"])
        copies = [call["args"] for call in self.calls if call["command"] == "rsync"]
        self.assertEqual(len(copies), 2)
        self.assertIn("guest@127.0.0.1:.", copies[0])
        self.assertEqual(copies[0][-1], str(self.stage / "mac" / "Users") + "/")
        self.assertEqual(self.stage.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.stage / ".lock").exists())

    def test_unmounted_volume_never_initializes_a_repository(self):
        result = self.run_backup(MISSING_VOLUME="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call["command"] for call in self.calls], ["mount"])
        self.assertFalse(self.stage.exists())

    def test_overlapping_paths_are_rejected_before_mutation(self):
        repository = Path(self.env["RESTIC_REPOSITORY"])
        data = repository / "data" / "backup-pack"
        data.parent.mkdir(parents=True)
        data.write_text("existing backup data")
        repository.chmod(0o755)
        alias = self.root / "repository-alias"
        alias.symlink_to(repository, target_is_directory=True)
        for stage in (repository, repository.parent, repository / "stage", alias,
                      alias / "stage", self.root / "missing" / ".." / "volume" / "repo"):
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                result = self.run_backup(VOOM_BACKUP_STAGE=str(stage), VM_LIST="[]")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must not overlap", result.stderr)
                self.assertEqual(data.read_text(), "existing backup data")
                self.assertEqual(repository.stat().st_mode & 0o777, 0o755)
                self.assertFalse((repository / ".lock").exists())
                self.assertEqual([call["command"] for call in self.calls], ["mount"])
        self.assertFalse((repository / "stage").exists())

    def test_cleanup_preserves_unowned_directories_and_symlinks(self):
        unrelated = self.stage / "unrelated" / "document"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("keep this file")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / MARKER).touch()
        link = self.stage / "linked"
        link.symlink_to(outside, target_is_directory=True)
        result = self.run_backup(VM_LIST="[]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(unrelated.read_text(), "keep this file")
        self.assertTrue(link.is_symlink())
        self.assertTrue((outside / MARKER).exists())

    def test_guest_cannot_claim_an_existing_unowned_directory(self):
        document = self.stage / "mac" / "document"
        document.parent.mkdir(parents=True)
        document.write_text("keep this file")
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(document.read_text(), "keep this file")
        self.assertFalse((document.parent / MARKER).exists())
        self.assertEqual([args[args.index("--host") + 1] for args in self.snapshots()], ["second"])

    def test_successful_backup_can_clean_up_its_staging_after_guest_deletion(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.log.unlink()
        result = self.run_backup(VM_LIST="[]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.stage / "mac").exists())
        self.assertFalse((self.stage / "second").exists())

    def test_failed_copy_skips_snapshot_and_continues_other_guests(self):
        result = self.run_backup(RSYNC_EXIT="23")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.snapshots()), 1)
        self.assertIn("second", self.snapshots()[0])

    def test_disappearing_guest_does_not_stop_other_backups(self):
        result = self.run_backup(FAIL_INFO="mac")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([args[args.index("--host") + 1] for args in self.snapshots()], ["second"])
        self.assertIn("mac: inspection failed", result.stderr)
        self.assertFalse((self.stage / ".lock").exists())

    @unittest.skipUnless(shutil.which("ssh"), "requires OpenSSH")
    def test_ssh_ignores_interactive_config_and_uses_only_the_backup_key(self):
        config = self.root / "interactive ssh config"
        config.write_text("Host *\n  UseKeychain yes\n  IdentityFile /interactive/key\n")
        ssh = shutil.which("ssh")
        control = subprocess.run([ssh, "-G", "-F", str(config), "127.0.0.1"],
                                 capture_output=True, text=True)
        if control.returncode == 0:
            self.assertIn("identityfile /interactive/key", control.stdout)
        else:
            self.assertIn("usekeychain", control.stderr.lower())
        result = self.run_backup(TEST_SSH=ssh, TEST_SSH_CONFIG=str(config),
                                 TEST_SSH_IDENTITY=self.env["VOOM_BACKUP_IDENTITY"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.snapshots()), 2)

    @unittest.skipUnless(shutil.which("rsync"), "requires rsync")
    def test_stalled_transfer_times_out_continues_and_releases_the_lock(self):
        rsync = shutil.which("rsync")
        commands = self.root / "bin"
        (commands / "rsync").write_text("#!" + sys.executable + '''
import os
import sys
args = ["--timeout=1" if arg.startswith("--timeout=") and int(arg.split("=", 1)[1]) > 0 else arg for arg in sys.argv[1:]]
os.execv(os.environ["TEST_RSYNC"], ["rsync", *args])
''')
        users = self.root / "guest Users"
        users.mkdir()
        (users / "important.txt").write_text("recover this file\n")
        ssh = commands / "ssh"
        ssh.write_text("#!" + sys.executable + '''
import os
import sys
import time
args = sys.argv[1:]
if args[args.index("-p") + 1] == os.environ.get("STALL_PORT"):
    time.sleep(60)
    sys.exit(1)
os.chdir(os.environ["TEST_USERS"])
os.execv(os.environ["TEST_RSYNC"], ["rsync", *args[args.index("rsync") + 1:]])
''')
        ssh.chmod(0o755)
        environment = {**self.env, "TEST_RSYNC": rsync, "TEST_USERS": str(users), "STALL_PORT": "2222"}
        with subprocess.Popen(["bash", str(self.script)], env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                self.fail("A stalled transfer blocked the remaining backups")
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertNotEqual(process.returncode, 0, stdout + stderr)
        self.assertIn("rsync exit 30", stderr)
        self.assertEqual([args[args.index("--host") + 1] for args in self.snapshots()], ["second"])
        self.assertEqual((self.stage / "second" / "Users" / "important.txt").read_text(), "recover this file\n")
        self.assertFalse((self.stage / ".lock").exists())
        self.log.unlink()
        result = self.run_backup(TEST_RSYNC=rsync, TEST_USERS=str(users))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.snapshots()), 2)

    def test_files_vanishing_during_copy_still_allow_a_snapshot(self):
        result = self.run_backup(RSYNC_EXIT="24")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.snapshots()), 2)

    def test_restic_failures_are_reported_and_other_guests_continue(self):
        for status in ("1", "3"):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                result = self.run_backup(RESTIC_EXIT=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.snapshots()), 2)

    def test_failed_discovery_does_not_initialize_or_prune(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        (orphan / MARKER).touch()
        result = self.run_backup(FAIL_VOOM="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call["command"] == "restic" for call in self.calls))
        self.assertFalse((self.stage / ".lock").exists())
        self.assertTrue(orphan.exists())

    def test_invalid_discovery_output_does_not_initialize_or_prune(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        (orphan / MARKER).touch()
        result = self.run_backup(INVALID_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call["command"] == "restic" for call in self.calls))
        self.assertTrue(orphan.exists())

    def test_cleanup_removes_deleted_guests_and_keeps_stopped_guests(self):
        for name in ("deleted", "stopped", "mac", "linux"):
            directory = self.stage / name
            directory.mkdir(parents=True)
            (directory / MARKER).touch()
            (directory / "data").write_text("previous staging")
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.stage / "deleted").exists())
        for name in ("stopped", "mac", "linux"):
            self.assertTrue((self.stage / name / "data").exists())

    def test_empty_inventory_removes_all_guest_staging(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        (orphan / MARKER).touch()
        result = self.run_backup(VM_LIST="[]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(orphan.exists())

    def test_wrong_inventory_type_does_not_remove_staging_or_change_repository(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        (orphan / MARKER).touch()
        for inventory in ("{}", "[{}]", '[{"name": "stopped", "status": null}]'):
            with self.subTest(inventory=inventory):
                self.log.unlink(missing_ok=True)
                result = self.run_backup(VM_LIST=inventory)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(orphan.exists())
                self.assertFalse(any(call["command"] == "restic" for call in self.calls))

    def test_missing_identity_stops_before_discovery_or_repository_changes(self):
        Path(self.env["VOOM_BACKUP_IDENTITY"]).unlink()
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not readable", result.stderr)
        self.assertEqual([call["command"] for call in self.calls], ["mount"])

    @unittest.skipUnless(all(shutil.which(command) for command in ("rsync", "rrsync", "restic")),
                         "requires rsync, rrsync, and restic")
    def test_real_restricted_copy_and_restic_restore(self):
        commands = self.root / "bin"
        for command in ("rsync", "restic"):
            (commands / command).unlink()
        users = self.root / "guest Users"
        document = users / "guest" / "Documents" / "important.txt"
        document.parent.mkdir(parents=True)
        document.write_text("recover this file\n")
        ssh = commands / "ssh"
        ssh.write_text("#!" + sys.executable + '''
import os
import sys
args = sys.argv[1:]
if args[args.index("-i") + 1] != os.environ["VOOM_BACKUP_IDENTITY"]:
    sys.exit("SSH identity path was split")
os.environ["SSH_ORIGINAL_COMMAND"] = " ".join(args[args.index("rsync"):])
os.execv(os.environ["TEST_RRSYNC"], ["rrsync", "-ro", os.environ["TEST_USERS"]])
''')
        ssh.chmod(0o755)
        Path(self.env["RESTIC_PASSWORD_FILE"]).write_text("test-password\n")
        Path(self.env["RESTIC_REPOSITORY"]).parent.mkdir()
        result = self.run_backup(TEST_RRSYNC=shutil.which("rrsync"), TEST_USERS=str(users))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restored = self.root / "restore"
        result = subprocess.run(["restic", "restore", "latest", "--host", "mac", "--target", str(restored)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        documents = list(restored.rglob("important.txt"))
        self.assertEqual(len(documents), 1)
        self.assertEqual(documents[0].read_text(), document.read_text())
        self.assertEqual(list(restored.rglob(MARKER)), [])
        self.log.unlink()
        result = self.run_backup(VOOM_BACKUP_STAGE=self.env["RESTIC_REPOSITORY"], VM_LIST="[]")
        self.assertNotEqual(result.returncode, 0)
        result = subprocess.run(["restic", "snapshots"], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class LinuxBackupTests(BackupFixture):
    script = Path(os.environ.get("VOOM_LINUX_BACKUP_SCRIPT", SCRIPT.with_name("voom-backup-linux")))

    def setUp(self):
        super().setUp()
        self.env.update({
            "VOOM_BACKUP_USER": "guest",
            "VOOM_BACKUP_IDENTITY": "/keys/key with spaces",
            "VOOM_BACKUP_RESTIC": "restic-backup-test",
        })

    def test_running_guests_copy_home_and_docker_volumes(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.snapshots()), 3)
        copies = [call["args"] for call in self.calls if call["command"] == "rsync"]
        self.assertEqual(len(copies), 6)
        self.assertIn("guest@127.0.0.1:/home/", copies[0])
        self.assertIn("guest@127.0.0.1:/var/lib/docker/volumes/", copies[1])
        ssh = shlex.split(copies[0][copies[0].index("-e") + 1])
        self.assertEqual(ssh[ssh.index("-i") + 1], "/keys/key with spaces")

    @unittest.skipUnless(shutil.which("ssh"), "requires OpenSSH")
    def test_ssh_ignores_interactive_config(self):
        config = self.root / "interactive ssh config"
        config.write_text("Host *\n  UseKeychain yes\n  IdentityFile /interactive/key\n")
        result = self.run_backup(TEST_SSH=shutil.which("ssh"), TEST_SSH_CONFIG=str(config))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.snapshots()), 3)

    def test_files_vanishing_during_copy_still_allow_snapshots(self):
        result = self.run_backup(RSYNC_EXIT="24")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.snapshots()), 3)

    def test_cleanup_removes_deleted_guests_and_keeps_stopped_guests(self):
        for name in ("deleted", "stopped"):
            (self.stage / name).mkdir(parents=True)
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.stage / "deleted").exists())
        self.assertTrue((self.stage / "stopped").exists())

    def test_empty_inventory_removes_all_staging_without_taking_snapshots(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        result = self.run_backup(VM_LIST="[]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(orphan.exists())
        self.assertEqual(self.snapshots(), [])

    def test_failed_or_invalid_discovery_preserves_staging(self):
        orphan = self.stage / "deleted"
        orphan.mkdir(parents=True)
        for environment in ({"FAIL_VOOM": "1"}, {"INVALID_LIST": "1"}, {"VM_LIST": "{}"}, {"VM_LIST": "[{}]"}):
            with self.subTest(environment=environment):
                self.log.unlink(missing_ok=True)
                result = self.run_backup(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(orphan.exists())
                self.assertEqual(self.snapshots(), [])

    def test_copy_and_snapshot_failures_fail_the_job_and_continue_other_guests(self):
        for environment, snapshots in (
            ({"RSYNC_EXIT": "23", "RSYNC_FAIL_PATH": "/home/"}, 2),
            ({"RSYNC_EXIT": "23", "RSYNC_FAIL_PATH": "/var/lib/docker/volumes/"}, 3),
            ({"RSYNC_EXIT": "30", "RSYNC_FAIL_PATH": "/home/"}, 2),
            ({"RESTIC_EXIT": "1"}, 3),
            ({"RESTIC_EXIT": "3"}, 3),
        ):
            with self.subTest(environment=environment):
                self.log.unlink(missing_ok=True)
                result = self.run_backup(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.snapshots()), snapshots)
                self.assertIn("second", self.snapshots()[-1])


if __name__ == "__main__":
    unittest.main()
