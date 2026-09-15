#!/usr/bin/env python3

import argparse
import base64
import contextlib
import fcntl
import json
import os
import pathlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SUPPORTED_AGENT_VAULT_VERSION = "0.39.3"
VM_ID_RE = re.compile(r"^[0-9A-Fa-f]{32}$")


class ManagerError(Exception):
    pass


class HTTPError(ManagerError):
    def __init__(self, status, message):
        super().__init__(f"Agent Vault returned HTTP {status}: {message}")
        self.status = status


def atomic_write(path, data, mode=0o600):
    path = pathlib.Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


def atomic_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def read_json(path):
    try:
        with open(path, "rb") as stream:
            return json.load(stream)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as error:
        raise ManagerError(f"cannot read {path}: {error}") from error


class Manager:
    def __init__(self, config_path):
        config = read_json(config_path)
        if not isinstance(config, dict):
            raise ManagerError(f"invalid manager configuration: {config_path}")
        self.config = config
        self.assignments = config.get("assignments", {})
        if not isinstance(self.assignments, dict) or not all(
            isinstance(name, str) and name and isinstance(profile, str) and profile
            for name, profile in self.assignments.items()
        ):
            raise ManagerError(
                "assignments must map nonempty VM names to nonempty profile names"
            )
        state_default = (
            pathlib.Path(
                os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")
            )
            / "voom-agent-vault"
        )
        self.state_dir = self._configured_directory(
            "stateDir", "VOOM_AGENT_VAULT_STATE_DIR", state_default
        )
        runtime_root = os.environ.get("XDG_RUNTIME_DIR")
        runtime_default = (
            pathlib.Path(runtime_root) / "voom-agent-vault"
            if runtime_root
            else pathlib.Path(f"/run/user/{os.getuid()}/voom-agent-vault")
        )
        self.runtime_dir = self._configured_directory(
            "runtimeDir", "VOOM_AGENT_VAULT_RUNTIME_DIR", runtime_default
        )
        self.attachments_dir = self.state_dir / "attachments"
        self.holds_dir = self.state_dir / "holds"
        self.voom = config["voom"]
        self.haproxy = config["haproxy"]
        self.agent_vault = config["agentVault"]
        self.address = config.get("address", "http://127.0.0.1:14321").rstrip("/")
        parsed_address = urllib.parse.urlparse(self.address)
        if (
            parsed_address.scheme != "http"
            or parsed_address.hostname not in ("127.0.0.1", "::1")
            or not parsed_address.port
            or parsed_address.path
            or parsed_address.query
            or parsed_address.fragment
        ):
            raise ManagerError(
                "Agent Vault management address must be a loopback HTTP origin"
            )
        self.management_address = (parsed_address.hostname, parsed_address.port)
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.proxy_address = config.get("proxyAddress", "127.0.0.1:14322")
        self.ca_path = pathlib.Path(config["caPath"])
        self.bridge_unit = config.get("bridgeUnit", "voom-agent-vault-bridge.service")
        self.firewall_status = pathlib.Path(
            config.get("firewallStatus", "/run/voom-agent-vault-firewall/status.json")
        )
        self.timeout = float(config.get("operationTimeoutSeconds", 60))
        self._admin_session = None
        self._admin_checked = False
        self._prepare_directories()

    def _configured_directory(self, config_key, environment_key, default):
        value = self.config.get(config_key, os.environ.get(environment_key, default))
        if not isinstance(value, (str, os.PathLike)):
            raise ManagerError(f"{config_key} must be an absolute path")
        path = pathlib.Path(str(value).replace("%U", str(os.getuid())))
        if not path.is_absolute():
            raise ManagerError(f"{config_key} must be an absolute path")
        return path

    def _prepare_directories(self):
        for path in (
            self.state_dir,
            self.attachments_dir,
            self.holds_dir,
            self.runtime_dir,
        ):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(path, 0o700)

    @contextlib.contextmanager
    def management_lock(self):
        path = self.runtime_dir / "management.lock"
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def run(self, argv, timeout=None, check=True):
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout or self.timeout)
        except subprocess.TimeoutExpired as error:
            process.kill()
            stdout, stderr = process.communicate()
            raise ManagerError(
                f"command timed out and was terminated: {argv[0]}"
            ) from error
        if check and process.returncode != 0:
            detail = stderr.strip() or stdout.strip() or f"exit {process.returncode}"
            raise ManagerError(f"{pathlib.Path(argv[0]).name}: {detail}")
        return process.returncode, stdout, stderr

    def voom_json(self, *args):
        _, stdout, _ = self.run([self.voom, "--output", "json", *args])
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as error:
            raise ManagerError(
                f"Voom returned invalid JSON for {' '.join(args)}"
            ) from error

    def list_vms(self):
        rows = self.voom_json("list")
        if not isinstance(rows, list):
            raise ManagerError("Voom list response is not an array")
        result = {}
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("name"), str):
                raise ManagerError("Voom list contains an invalid VM record")
            if not VM_ID_RE.fullmatch(row.get("id", "")):
                raise ManagerError(
                    f"Voom returned an invalid ID for VM {row['name']!r}"
                )
            result[row["name"]] = row
        return result

    def vm_info(self, name):
        result = self.voom_json("info", name)
        vm = result.get("vm", {})
        vm_id = vm.get("id", "")
        if not VM_ID_RE.fullmatch(vm_id):
            raise ManagerError(f"Voom returned an invalid ID for VM {name!r}")
        return result

    def voom_egress(self, action, name, vm_id, *arguments):
        return self.voom_json(
            "config", "egress", action, name, "--expect-id", vm_id, *arguments
        )

    def attachment_path(self, vm_id):
        return self.attachments_dir / vm_id / "attachment.json"

    def token_path(self, vm_id):
        return self.attachments_dir / vm_id / "token"

    def load_attachment(self, vm_id):
        attachment = read_json(self.attachment_path(vm_id))
        if attachment is None:
            return None
        expected_agent = f"voom-{vm_id.lower()}"
        expected_socket = str(self.runtime_dir / f"{vm_id}.sock")
        if (
            not isinstance(attachment, dict)
            or attachment.get("schemaVersion") != 1
            or attachment.get("vmID") != vm_id
            or attachment.get("agentName") != expected_agent
            or attachment.get("socket") != expected_socket
            or not isinstance(attachment.get("profile"), str)
            or attachment.get("vault") != attachment.get("profile")
            or not isinstance(attachment.get("desiredEnabled"), bool)
            or not isinstance(attachment.get("lastKnownName"), str)
            or not (
                attachment.get("pendingOperation") is None
                or isinstance(attachment.get("pendingOperation"), dict)
            )
        ):
            raise ManagerError(f"invalid attachment record for VM ID {vm_id}")
        return attachment

    def save_attachment(self, attachment):
        current = self.load_attachment(attachment["vmID"])
        if current is not None:
            current.update(attachment)
            attachment = current
        atomic_json(self.attachment_path(attachment["vmID"]), attachment)

    def all_attachments(self):
        attachments = {}
        if not self.attachments_dir.exists():
            return attachments
        for directory in sorted(self.attachments_dir.iterdir()):
            if directory.is_dir() and VM_ID_RE.fullmatch(directory.name):
                attachment = self.load_attachment(directory.name)
                if attachment is not None:
                    attachments[directory.name] = attachment
        return attachments

    def find_attachment(self, name, vms=None):
        vms = vms or self.list_vms()
        if name in vms:
            attachment = self.load_attachment(vms[name]["id"])
            return vms[name]["id"], attachment
        matches = [
            (vm_id, attachment)
            for vm_id, attachment in self.all_attachments().items()
            if attachment.get("lastKnownName") == name
        ]
        if len(matches) != 1:
            raise ManagerError(f"no unique attachment or VM named {name!r}")
        return matches[0]

    def hold_paths(self, vm_id):
        directory = self.holds_dir / vm_id
        if not directory.exists():
            return []
        return sorted(path for path in directory.glob("*.json") if path.is_file())

    def holds(self, vm_id):
        result = []
        for path in self.hold_paths(vm_id):
            hold = read_json(path)
            if isinstance(hold, dict) and hold.get("vmID") == vm_id:
                hold["_path"] = str(path)
                result.append(hold)
        return result

    def has_hold(self, vm_id):
        return bool(self.hold_paths(vm_id))

    def create_hold(self, vm_id, reason):
        request_id = uuid.uuid4().hex
        hold = {
            "schemaVersion": 1,
            "requestID": request_id,
            "vmID": vm_id,
            "createdAt": int(time.time()),
            "state": "pending",
        }
        if reason:
            hold["reason"] = reason
        atomic_json(self.holds_dir / vm_id / f"{request_id}.json", hold)
        return request_id

    def activate_pending_holds(self, vm_id):
        for hold in self.holds(vm_id):
            if hold.get("state") != "pending":
                continue
            path = hold.pop("_path")
            hold["state"] = "active"
            hold["completedAt"] = int(time.time())
            atomic_json(path, hold)

    def _decl(self, info):
        return info.get("vm", {}).get("network", {}).get("egress")

    def _decl_matches(self, info, attachment):
        decl = self._decl(info)
        return bool(
            decl
            and info.get("vm", {}).get("id") == attachment["vmID"]
            and decl.get("mode") == "explicit"
            and decl.get("backendSocket") == attachment["socket"]
            and decl.get("caCertPath", "") == str(self.ca_path)
        )

    def ensure_disabled(self, name, vm_id):
        try:
            info = self.vm_info(name)
        except ManagerError:
            return False
        decl = self._decl(info)
        if decl is None or not decl.get("enabled", False):
            self.activate_pending_holds(vm_id)
            return True
        try:
            self.voom_egress("disable", name, vm_id)
        except ManagerError:
            pass
        info = self.vm_info(name)
        decl = self._decl(info)
        confirmed = decl is None or not decl.get("enabled", False)
        if confirmed:
            self.activate_pending_holds(vm_id)
        return confirmed

    def enable_voom_with_hold_checks(self, name, vm_id):
        if self.has_hold(vm_id):
            if not self.ensure_disabled(name, vm_id):
                raise ManagerError(
                    "an emergency hold exists and disabled state cannot be confirmed"
                )
            return False
        enable_error = None
        try:
            self.voom_egress("enable", name, vm_id)
        except ManagerError as error:
            enable_error = error
        if self.has_hold(vm_id):
            if not self.ensure_disabled(name, vm_id):
                raise ManagerError("a concurrent emergency hold could not be confirmed")
            raise ManagerError("a concurrent emergency hold prevents enable")
        if enable_error is not None:
            raise enable_error
        return True

    def _session(self):
        if self._admin_session is not None:
            return self._admin_session
        path = pathlib.Path.home() / ".agent-vault" / "session.json"
        session = read_json(path)
        if (
            not isinstance(session, dict)
            or not session.get("token")
            or not session.get("address")
        ):
            raise ManagerError(
                "Agent Vault login is required; run 'agent-vault auth login' first"
            )
        if session["address"].rstrip("/") != self.address:
            raise ManagerError(
                f"Agent Vault session targets {session['address']}, expected {self.address}"
            )
        self._admin_session = session
        return session

    def api(
        self, method, path, payload=None, token=None, vault=None, authenticated=True
    ):
        body = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        if authenticated:
            token = token or self._session()["token"]
            headers["Authorization"] = f"Bearer {token}"
        if vault:
            headers["X-Vault"] = vault
        request = urllib.request.Request(
            self.address + path, data=body, headers=headers, method=method
        )
        try:
            with self.http.open(request, timeout=self.timeout) as response:
                data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024:
                    raise ManagerError("Agent Vault response exceeded 4 MiB")
        except urllib.error.HTTPError as error:
            detail = error.read(4096)
            try:
                message = json.loads(detail).get(
                    "error", detail.decode(errors="replace")
                )
            except json.JSONDecodeError:
                message = detail.decode(errors="replace")
            raise HTTPError(error.code, str(message).strip()) from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise ManagerError(f"cannot reach Agent Vault: {error}") from error
        if not data:
            return {}
        try:
            return json.loads(data)
        except json.JSONDecodeError as error:
            raise ManagerError("Agent Vault returned invalid JSON") from error

    def require_admin(self):
        if self._admin_checked:
            return
        _, stdout, _ = self.run([self.agent_vault, "version"])
        first_line = stdout.splitlines()[0] if stdout else ""
        if first_line != f"agent-vault {SUPPORTED_AGENT_VAULT_VERSION}":
            raise ManagerError(
                f"unsupported Agent Vault version {first_line!r}; expected {SUPPORTED_AGENT_VAULT_VERSION}"
            )
        self.api("GET", "/v1/agents")
        self.api("GET", "/v1/vaults")
        self._admin_checked = True

    def vault_exists(self, vault):
        self.require_admin()
        response = self.api("GET", "/v1/vaults")
        return any(item.get("name") == vault for item in response.get("vaults", []))

    def get_agent(self, agent_name):
        self.require_admin()
        path = "/v1/agents/" + urllib.parse.quote(agent_name, safe="")
        try:
            return self.api("GET", path)
        except HTTPError as error:
            if error.status == 404:
                return None
            raise

    def create_agent(self, agent_name, vault):
        response = self.api(
            "POST",
            "/v1/agents",
            {
                "name": agent_name,
                "role": "no-access",
                "vaults": [{"vault_name": vault, "vault_role": "proxy"}],
            },
        )
        token = response.get("av_agent_token")
        if not token:
            raise ManagerError("Agent Vault did not return the new agent token")
        return token

    def add_grant(self, agent_name, vault):
        self.api(
            "POST",
            f"/v1/vaults/{urllib.parse.quote(vault, safe='')}/agents",
            {"name": agent_name, "role": "proxy"},
        )

    def remove_grant(self, agent_name, vault):
        path = (
            f"/v1/vaults/{urllib.parse.quote(vault, safe='')}/agents/"
            f"{urllib.parse.quote(agent_name, safe='')}"
        )
        try:
            self.api("DELETE", path)
        except HTTPError as error:
            if error.status != 404:
                raise

    def rotate_agent(self, agent_name):
        response = self.api(
            "POST", f"/v1/agents/{urllib.parse.quote(agent_name, safe='')}/rotate", {}
        )
        token = response.get("av_agent_token")
        if not token:
            raise ManagerError("Agent Vault did not return the rotated token")
        return token

    def revoke_agent(self, agent_name):
        agent = self.get_agent(agent_name)
        if agent is None or agent.get("status") == "revoked":
            return
        try:
            self.api("DELETE", f"/v1/agents/{urllib.parse.quote(agent_name, safe='')}")
        except HTTPError as error:
            if error.status != 404:
                raise

    def ensure_agent(self, attachment):
        vault = attachment["vault"]
        if not self.vault_exists(vault):
            raise ManagerError(f"Agent Vault vault {vault!r} does not exist")
        agent = self.get_agent(attachment["agentName"])
        if agent is None:
            return self.create_agent(attachment["agentName"], vault)
        if agent.get("status") == "revoked":
            self.api(
                "POST",
                f"/v1/agents/{urllib.parse.quote(attachment['agentName'], safe='')}/delete",
                {},
            )
            return self.create_agent(attachment["agentName"], vault)
        grants = {
            item.get("vault_name"): item.get("vault_role")
            for item in agent.get("vaults", [])
        }
        for existing in sorted(grants):
            if existing != vault:
                self.remove_grant(attachment["agentName"], existing)
        if grants.get(vault) != "proxy":
            if vault in grants:
                self.remove_grant(attachment["agentName"], vault)
            self.add_grant(attachment["agentName"], vault)
        if not self.valid_token_file(attachment["vmID"]):
            return self.rotate_agent(attachment["agentName"])
        return None

    def valid_token_file(self, vm_id):
        path = self.token_path(vm_id)
        try:
            info = path.lstat()
        except FileNotFoundError:
            return False
        return (
            stat.S_ISREG(info.st_mode)
            and not path.is_symlink()
            and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_size > 0
        )

    def write_token(self, vm_id, token):
        if not isinstance(token, str) or not token:
            raise ManagerError("refusing to write an empty Agent Vault token")
        atomic_write(self.token_path(vm_id), (token + "\n").encode())

    def read_token(self, vm_id):
        if not self.valid_token_file(vm_id):
            raise ManagerError(f"token file for VM ID {vm_id} is missing or unsafe")
        return self.token_path(vm_id).read_text().strip()

    def verify_token(self, attachment):
        token = self.read_token(attachment["vmID"])
        response = self.api(
            "GET",
            "/discover",
            token=token,
            vault=attachment["vault"],
            authenticated=True,
        )
        if response.get("vault") != attachment["vault"]:
            raise ManagerError("agent token resolved to the wrong vault")

    def ensure_verified_token(self, attachment):
        token = self.ensure_agent(attachment)
        if token is not None:
            self.write_token(attachment["vmID"], token)
        try:
            self.verify_token(attachment)
        except HTTPError as error:
            if error.status != 401:
                raise
            token = self.rotate_agent(attachment["agentName"])
            self.write_token(attachment["vmID"], token)
            self.verify_token(attachment)

    def _bridge_config(self, attachments, token_map_path):
        lines = [
            "global",
            "  log stderr format raw local0",
            "",
            "defaults",
            "  mode http",
            "  log global",
            "  option httplog",
            "  option dontlognull",
            "  timeout connect 10s",
            "  timeout client 15m",
            "  timeout server 15m",
            "  timeout tunnel 15m",
            "  log-format bridge\\ frontend=%ft\\ status=%ST\\ bytes=%B",
            "",
            "backend agent_vault",
            "  http-reuse never",
            f"  server agent-vault {self.proxy_address}",
            "",
        ]
        if not attachments:
            lines.extend(
                [
                    "frontend no_attachments",
                    f"  bind {self.runtime_dir / 'bridge-health.sock'} mode 600",
                    "  http-request deny deny_status 503",
                    "",
                ]
            )
        for attachment in attachments:
            frontend = "vm_" + attachment["vmID"].lower()
            lines.extend(
                [
                    f"frontend {frontend}",
                    f"  bind {attachment['socket']} mode 600",
                    f"  http-request set-var(txn.av_auth) str({frontend}),map({token_map_path})",
                    "  http-request deny deny_status 403 if !{ var(txn.av_auth) -m found }",
                    "  http-request del-header Proxy-Authorization",
                    '  http-request set-header Proxy-Authorization "Basic %[var(txn.av_auth)]"',
                    "  default_backend agent_vault",
                    "",
                ]
            )
        return ("\n".join(lines) + "\n").encode()

    def render_bridge(self):
        usable = []
        map_lines = []
        for vm_id, attachment in sorted(self.all_attachments().items()):
            if not self.valid_token_file(vm_id):
                continue
            socket_path = pathlib.Path(attachment.get("socket", ""))
            if (
                socket_path.parent != self.runtime_dir
                or socket_path.name != f"{vm_id}.sock"
            ):
                raise ManagerError(f"unsafe socket path in attachment {vm_id}")
            token = self.read_token(vm_id)
            encoded = base64.b64encode(
                f"{token}:{attachment['vault']}".encode()
            ).decode()
            frontend = "vm_" + vm_id.lower()
            map_lines.append(f"{frontend} {encoded}\n")
            usable.append(attachment)

        generations = self.runtime_dir / "generations"
        generations.mkdir(mode=0o700, exist_ok=True)
        generation = pathlib.Path(
            tempfile.mkdtemp(prefix="generation-", dir=generations)
        )
        os.chmod(generation, 0o700)
        staged_map = generation / "tokens.map"
        staged_config = generation / "haproxy.cfg"
        try:
            atomic_write(staged_map, "".join(map_lines).encode())
            atomic_write(staged_config, self._bridge_config(usable, staged_map))
            self.run([self.haproxy, "-c", "-f", str(staged_config)])
        except BaseException:
            shutil.rmtree(generation, ignore_errors=True)
            raise

        active = self.runtime_dir / "current"
        previous = None
        if active.is_symlink():
            previous = os.readlink(active)
        atomic_write(staged_config, self._bridge_config(usable, active / "tokens.map"))
        temporary_link = self.runtime_dir / f".current.{uuid.uuid4().hex}"
        os.symlink(os.path.relpath(generation, self.runtime_dir), temporary_link)
        os.replace(temporary_link, active)
        try:
            self.run([self.haproxy, "-c", "-f", str(active / "haproxy.cfg")])
        except BaseException:
            if previous is None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(active)
            else:
                rollback = self.runtime_dir / f".current.{uuid.uuid4().hex}"
                os.symlink(previous, rollback)
                os.replace(rollback, active)
            shutil.rmtree(generation, ignore_errors=True)
            raise
        return len(usable)

    def prune_bridge_generations(self):
        active = self.runtime_dir / "current"
        active_generation = None
        if active.is_symlink():
            active_generation = (self.runtime_dir / os.readlink(active)).resolve()
        generations = self.runtime_dir / "generations"
        if not generations.is_dir():
            return
        for generation in generations.iterdir():
            if not generation.name.startswith("generation-"):
                continue
            if generation.resolve() == active_generation:
                continue
            if generation.is_symlink() or not generation.is_dir():
                generation.unlink()
            else:
                shutil.rmtree(generation)

    def reload_bridge(self):
        self.run(
            ["systemctl", "--user", "reload-or-restart", self.bridge_unit], timeout=30
        )

    def render_and_reload_bridge(self):
        active = self.runtime_dir / "current"
        previous = os.readlink(active) if active.is_symlink() else None
        count = self.render_bridge()
        try:
            self.reload_bridge()
        except ManagerError as reload_error:
            if previous is None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(active)
            else:
                rollback = self.runtime_dir / f".current.{uuid.uuid4().hex}"
                os.symlink(previous, rollback)
                os.replace(rollback, active)
            rollback_error = None
            try:
                if previous is None:
                    self.run(
                        ["systemctl", "--user", "stop", self.bridge_unit], timeout=30
                    )
                else:
                    self.reload_bridge()
            except ManagerError as error:
                rollback_error = error
            if rollback_error is not None:
                self.prune_bridge_generations()
                raise ManagerError(
                    f"{reload_error}; bridge rollback also failed: {rollback_error}"
                ) from reload_error
            self.prune_bridge_generations()
            raise
        self.prune_bridge_generations()
        return count

    def verify_socket(self, attachment, timeout=5):
        deadline = time.monotonic() + timeout
        last_error = None
        while True:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(min(0.5, max(0.01, deadline - time.monotonic())))
            try:
                client.connect(attachment["socket"])
                return
            except OSError as error:
                last_error = error
            finally:
                client.close()
            if time.monotonic() >= deadline:
                raise ManagerError(
                    f"bridge socket is unavailable for {attachment['lastKnownName']}: {last_error}"
                ) from last_error
            time.sleep(0.05)

    def new_attachment(self, name, vm_id, profile):
        return {
            "schemaVersion": 1,
            "vmID": vm_id,
            "lastKnownName": name,
            "profile": profile,
            "vault": profile,
            "agentName": f"voom-{vm_id.lower()}",
            "socket": str(self.runtime_dir / f"{vm_id}.sock"),
            "desiredEnabled": True,
            "pendingOperation": {
                "kind": "attach",
                "phase": "created",
                "restoreEnabled": True,
            },
        }

    def set_pending(self, attachment, kind, phase, **extra):
        pending = {
            "kind": kind,
            "phase": phase,
            "restoreEnabled": attachment["desiredEnabled"],
        }
        pending.update(extra)
        attachment["pendingOperation"] = pending
        self.save_attachment(attachment)

    def reconcile_attachment(self, name, profile, row):
        vm_id = row["id"]
        attachment = self.load_attachment(vm_id)
        info = self.vm_info(name)
        if attachment is None and info.get("running", False):
            raise ManagerError("attach pending: VM must be stopped")
        if attachment is None:
            attachment = self.new_attachment(name, vm_id, profile)
            self.save_attachment(attachment)
        attachment["lastKnownName"] = name

        if self.has_hold(vm_id) and not self.ensure_disabled(name, vm_id):
            raise ManagerError(
                "emergency hold is pending; disabled state is unconfirmed"
            )

        if attachment["profile"] != profile:
            self.change_profile(name, attachment, profile)
            return

        exact_before = self._decl_matches(info, attachment)
        if not exact_before and info.get("running", False):
            decl = self._decl(info)
            if decl and decl.get("enabled"):
                self.ensure_disabled(name, vm_id)
            raise ManagerError(
                "attach pending: VM must be stopped to replace its egress declaration"
            )

        if (
            exact_before
            and not self._decl(info).get("enabled", False)
            and attachment.get("pendingOperation") is None
            and attachment.get("desiredEnabled", True)
            and not self.has_hold(vm_id)
        ):
            attachment["desiredEnabled"] = False
            self.save_attachment(attachment)

        self.set_pending(attachment, "attach", "agent")
        self.ensure_verified_token(attachment)
        self.set_pending(attachment, "attach", "bridge")
        self.render_and_reload_bridge()
        self.verify_socket(attachment)

        info = self.vm_info(name)
        if not self._decl_matches(info, attachment):
            if info.get("running", False):
                raise ManagerError(
                    "attach pending: VM must be stopped to store its egress declaration"
                )
            self.set_pending(attachment, "attach", "voom-set")
            try:
                self.voom_egress(
                    "set",
                    name,
                    vm_id,
                    "--disabled",
                    "--backend-socket",
                    attachment["socket"],
                    "--ca-cert",
                    str(self.ca_path),
                )
            except ManagerError:
                info = self.vm_info(name)
                if not self._decl_matches(info, attachment):
                    raise
            info = self.vm_info(name)
            if not self._decl_matches(info, attachment) or self._decl(info).get(
                "enabled", False
            ):
                raise ManagerError(
                    "Voom did not store the expected disabled egress declaration"
                )

        self.set_pending(attachment, "attach", "enable")
        if attachment.get("desiredEnabled", True) and not self.has_hold(vm_id):
            self.enable_voom_with_hold_checks(name, vm_id)
        else:
            self.ensure_disabled(name, vm_id)
        attachment["pendingOperation"] = None
        self.save_attachment(attachment)

    def change_profile(self, name, attachment, profile):
        vm_id = attachment["vmID"]
        old_profile = attachment["profile"]
        self.set_pending(
            attachment,
            "profile-change",
            "disable",
            sourceProfile=old_profile,
            targetProfile=profile,
        )
        if not self.ensure_disabled(name, vm_id):
            raise ManagerError("cannot confirm disabled state before profile change")
        self.require_admin()
        if not self.vault_exists(profile):
            raise ManagerError(f"Agent Vault vault {profile!r} does not exist")
        self.set_pending(
            attachment,
            "profile-change",
            "grants",
            sourceProfile=old_profile,
            targetProfile=profile,
        )
        self.remove_grant(attachment["agentName"], old_profile)
        agent = self.get_agent(attachment["agentName"])
        grants = {item.get("vault_name") for item in (agent or {}).get("vaults", [])}
        for existing in sorted(grant for grant in grants if grant and grant != profile):
            self.remove_grant(attachment["agentName"], existing)
        if profile not in grants:
            self.add_grant(attachment["agentName"], profile)
        token = self.rotate_agent(attachment["agentName"])
        self.write_token(vm_id, token)
        attachment["profile"] = profile
        attachment["vault"] = profile
        self.set_pending(
            attachment,
            "profile-change",
            "bridge",
            sourceProfile=old_profile,
            targetProfile=profile,
        )
        self.render_and_reload_bridge()
        self.verify_socket(attachment)
        self.verify_token(attachment)
        if attachment.get("desiredEnabled", True) and not self.has_hold(vm_id):
            self.enable_voom_with_hold_checks(name, vm_id)
        attachment["pendingOperation"] = None
        self.save_attachment(attachment)

    def sync(self):
        failures = []
        with self.management_lock():
            vms = self.list_vms()
            for name, profile in sorted(self.assignments.items()):
                row = vms.get(name)
                if row is None:
                    print(f"{name}: pending; VM does not exist")
                    continue
                try:
                    self.reconcile_attachment(name, profile, row)
                    print(f"{name}: attached to profile {profile}")
                except ManagerError as error:
                    with contextlib.suppress(ManagerError):
                        if self.has_hold(row["id"]):
                            self.ensure_disabled(name, row["id"])
                    print(f"{name}: {error}", file=sys.stderr)
                    failures.append(name)

            current_by_id = {row["id"]: name for name, row in vms.items()}
            for vm_id, attachment in self.all_attachments().items():
                current_name = current_by_id.get(vm_id)
                name = current_name or attachment["lastKnownName"]
                if current_name is not None and current_name in self.assignments:
                    continue
                try:
                    self.detach_one(name, vm_id, attachment, current_name is not None)
                    print(f"{name}: detached")
                except ManagerError as error:
                    print(f"{name}: detach pending: {error}", file=sys.stderr)
                    failures.append(name)
        if failures:
            raise ManagerError(
                f"synchronization incomplete for {len(set(failures))} VM(s)"
            )

    def detach_one(self, name, vm_id, attachment, vm_exists=True):
        self.set_pending(attachment, "detach", "disable")
        attachment["desiredEnabled"] = False
        self.save_attachment(attachment)
        if vm_exists and not self.ensure_disabled(name, vm_id):
            raise ManagerError("cannot confirm disabled state")
        self.require_admin()
        self.set_pending(attachment, "detach", "revoke")
        self.revoke_agent(attachment["agentName"])
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.token_path(vm_id))
        self.render_and_reload_bridge()
        if vm_exists:
            info = self.vm_info(name)
            if info.get("running", False):
                raise ManagerError(
                    "VM must be stopped before its egress declaration can be cleared"
                )
            if self._decl(info) is not None:
                self.voom_egress("clear", name, vm_id)
                if self._decl(self.vm_info(name)) is not None:
                    raise ManagerError("Voom egress declaration remains after clear")
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.attachment_path(vm_id))
        with contextlib.suppress(OSError):
            os.rmdir(self.attachments_dir / vm_id)

    def detach(self, name):
        with self.management_lock():
            vms = self.list_vms()
            vm_id, attachment = self.find_attachment(name, vms)
            if attachment is None:
                raise ManagerError(f"VM {name!r} has no applied attachment")
            self.detach_one(name, vm_id, attachment, name in vms)

    def disable(self, name, reason):
        vms = self.list_vms()
        if name in vms:
            vm_id = vms[name]["id"]
        else:
            vm_id, _ = self.find_attachment(name, vms)
        request_id = self.create_hold(vm_id, reason)
        if not self.ensure_disabled(name, vm_id):
            raise ManagerError(
                f"hold {request_id} is pending; disabled state could not be confirmed"
            )
        print(f"{name}: disabled; hold {request_id} is active")

    def enable(self, name):
        with self.management_lock():
            vms = self.list_vms()
            vm_id, attachment = self.find_attachment(name, vms)
            if attachment is None:
                raise ManagerError(f"VM {name!r} has no applied attachment; run sync")
            pending = attachment.get("pendingOperation")
            if pending:
                raise ManagerError("attachment has a pending operation; run sync")
            holds = self.holds(vm_id)
            if any(hold.get("state") != "active" for hold in holds):
                raise ManagerError(
                    "an emergency hold is not confirmed; rerun disable or sync"
                )
            authorized = {hold["requestID"]: hold["_path"] for hold in holds}
            info = self.vm_info(name)
            if not self._decl_matches(info, attachment):
                raise ManagerError(
                    "Voom egress declaration does not match this attachment; run sync"
                )
            self.verify_token(attachment)
            if not self.ca_path.is_file():
                raise ManagerError("public Agent Vault CA is unavailable")
            self.render_and_reload_bridge()
            self.verify_socket(attachment)
            attachment["desiredEnabled"] = True
            self.save_attachment(attachment)
            for path in authorized.values():
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
            if self.has_hold(vm_id):
                self.ensure_disabled(name, vm_id)
                raise ManagerError("a concurrent emergency hold prevents enable")
            self.enable_voom_with_hold_checks(name, vm_id)
            print(f"{name}: enabled")

    def rotate(self, name):
        with self.management_lock():
            vm_id, attachment = self.find_attachment(name)
            if attachment is None:
                raise ManagerError(f"VM {name!r} has no applied attachment")
            self.set_pending(attachment, "rotate", "disable")
            if not self.ensure_disabled(name, vm_id):
                raise ManagerError(
                    "cannot confirm disabled state before token rotation"
                )
            self.require_admin()
            self.set_pending(attachment, "rotate", "token")
            self.write_token(vm_id, self.rotate_agent(attachment["agentName"]))
            self.set_pending(attachment, "rotate", "bridge")
            self.render_and_reload_bridge()
            self.verify_socket(attachment)
            self.verify_token(attachment)
            if attachment.get("desiredEnabled", True) and not self.has_hold(vm_id):
                self.enable_voom_with_hold_checks(name, vm_id)
            attachment["pendingOperation"] = None
            self.save_attachment(attachment)
            print(f"{name}: token rotated")

    def _probe_tcp(self, address):
        host, port = address.rsplit(":", 1)
        try:
            with socket.create_connection((host, int(port)), timeout=2):
                return True
        except OSError:
            return False

    def _probe_management(self):
        request = urllib.request.Request(self.address + "/health", method="GET")
        try:
            with self.http.open(request, timeout=2) as response:
                return response.status == 200
        except (urllib.error.URLError, TimeoutError, OSError):
            return False

    def _unit_active(self, unit, user=False):
        argv = ["systemctl"]
        if user:
            argv.append("--user")
        argv.extend(["is-active", "--quiet", unit])
        code, _, _ = self.run(argv, timeout=5, check=False)
        return code == 0

    def status(self, selected=None, as_json=False):
        errors = []
        vms = self.list_vms()
        attachments = self.all_attachments()
        names_by_id = {row["id"]: name for name, row in vms.items()}
        rows = []
        desired_names = set(self.assignments)
        desired_ids = {vms[name]["id"] for name in desired_names if name in vms}
        applied_ids = set(attachments)
        for name in sorted(desired_names):
            if selected and name != selected:
                continue
            vm = vms.get(name)
            attachment = attachments.get(vm["id"]) if vm else None
            holds = self.holds(vm["id"]) if vm else []
            info = None
            if vm:
                try:
                    info = self.vm_info(name)
                except ManagerError as error:
                    errors.append(f"{name}: cannot inspect Voom egress state: {error}")
            declaration = self._decl(info) if info else None
            runtime = info.get("egressRuntime") if info else None
            declared_enabled = bool(declaration and declaration.get("enabled"))
            held = bool(holds)
            row = {
                "name": name,
                "desiredProfile": self.assignments[name],
                "vmID": vm.get("id") if vm else None,
                "vmStatus": vm.get("status") if vm else "missing",
                "appliedProfile": attachment.get("profile") if attachment else None,
                "agentName": attachment.get("agentName") if attachment else None,
                "desiredEnabled": attachment.get("desiredEnabled")
                if attachment
                else None,
                "effectiveEnabled": declared_enabled and not held,
                "voomEgress": declaration,
                "voomEgressRuntime": runtime,
                "tokenPresent": self.valid_token_file(vm["id"])
                if attachment
                else False,
                "socketPresent": pathlib.Path(attachment["socket"]).is_socket()
                if attachment
                else False,
                "holds": [
                    {key: value for key, value in hold.items() if key != "_path"}
                    for hold in holds
                ],
                "pendingOperation": attachment.get("pendingOperation")
                if attachment
                else None,
            }
            row["drift"] = (
                not attachment or attachment.get("profile") != self.assignments[name]
            )
            row["reverseDrift"] = bool(
                attachment
                and declared_enabled
                and (not attachment.get("desiredEnabled", True) or held)
            )
            row["caConsistent"] = bool(
                attachment
                and declaration
                and declaration.get("caCertPath", "") == str(self.ca_path)
                and (
                    not runtime
                    or (
                        runtime.get("inSync", False)
                        and runtime.get("caPresent", False) == declared_enabled
                    )
                )
            )
            if row["drift"]:
                errors.append(f"{name}: desired and applied state differ")
            if row["reverseDrift"]:
                errors.append(f"{name}: Voom egress is enabled against manager state")
            if attachment and declaration and not row["caConsistent"]:
                errors.append(f"{name}: Voom and Agent Vault CA state differ")
            if runtime and not runtime.get("inSync", False):
                detail = (
                    runtime.get("error") or "runtime state differs from declaration"
                )
                errors.append(f"{name}: Voom egress runtime is out of sync: {detail}")
            if attachment and not row["tokenPresent"]:
                errors.append(f"{name}: Agent Vault token is missing or unsafe")
            if attachment and not row["socketPresent"]:
                errors.append(f"{name}: HAProxy frontend socket is missing")
            if attachment and row["pendingOperation"] is not None:
                errors.append(f"{name}: attachment operation is pending")
            rows.append(row)
        for vm_id in sorted(applied_ids):
            current_name = names_by_id.get(vm_id)
            name = current_name or attachments[vm_id].get("lastKnownName")
            if vm_id in desired_ids or (selected and name != selected):
                continue
            holds = self.holds(vm_id)
            rows.append(
                {
                    "name": name,
                    "vmID": vm_id,
                    "vmStatus": vms[current_name].get("status")
                    if current_name
                    else "missing",
                    "desiredProfile": None,
                    "appliedProfile": attachments[vm_id].get("profile"),
                    "holds": [
                        {key: value for key, value in hold.items() if key != "_path"}
                        for hold in holds
                    ],
                    "orphaned": True,
                }
            )
            errors.append(f"{name}: orphaned attachment")

        known_ids = desired_ids | applied_ids
        for directory in sorted(self.holds_dir.iterdir()):
            if not directory.is_dir() or not VM_ID_RE.fullmatch(directory.name):
                continue
            vm_id = directory.name
            if vm_id in known_ids:
                continue
            holds = self.holds(vm_id)
            if not holds:
                continue
            name = names_by_id.get(vm_id) or "unknown"
            if selected and name != selected:
                continue
            rows.append(
                {
                    "name": name,
                    "vmID": vm_id,
                    "vmStatus": "missing",
                    "desiredProfile": None,
                    "appliedProfile": None,
                    "holds": [
                        {key: value for key, value in hold.items() if key != "_path"}
                        for hold in holds
                    ],
                    "orphanedHold": True,
                }
            )
            errors.append(f"{name}: orphaned hold for VM ID {vm_id}")

        firewall = read_json(self.firewall_status)
        freshness = int(self.config.get("firewallFreshnessSeconds", 90))
        firewall_ok = bool(
            firewall
            and firewall.get("ok") is True
            and time.time() - firewall.get("timestamp", 0) <= freshness
        )
        health = {
            "agentVaultManagement": self._probe_management(),
            "agentVaultProxy": self._probe_tcp(self.proxy_address),
            "agentVaultUnit": self._unit_active("agent-vault.service"),
            "firewallUnit": self._unit_active("voom-agent-vault-firewall.service"),
            "bridgeUnit": self._unit_active(self.bridge_unit, user=True),
            "firewallVerifier": firewall,
            "firewallVerifierFresh": firewall_ok,
            "caPresent": self.ca_path.is_file(),
        }
        for key, value in health.items():
            if key != "firewallVerifier" and not value:
                errors.append(f"health check failed: {key}")
        result = {"health": health, "attachments": rows, "errors": errors}
        if as_json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            for row in rows:
                desired = row.get("desiredProfile") or "-"
                applied = row.get("appliedProfile") or "-"
                suffix = " drift" if row.get("drift") or row.get("orphaned") else ""
                print(
                    f"{row['name']}: vm={row.get('vmStatus')} desired={desired} applied={applied}{suffix}"
                )
            for key, value in health.items():
                if key != "firewallVerifier":
                    print(f"{key}: {'ok' if value else 'ERROR'}")
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
        if errors:
            raise ManagerError(f"status found {len(errors)} error(s)")


def parser():
    command = argparse.ArgumentParser(prog="voom-agent-vault")
    command.add_argument(
        "--config",
        default=os.environ.get(
            "VOOM_AGENT_VAULT_CONFIG", "/etc/voom-agent-vault/config.json"
        ),
    )
    subcommands = command.add_subparsers(dest="command", required=True)
    subcommands.add_parser("sync")
    subcommands.add_parser("render-bridge")
    status = subcommands.add_parser("status")
    status.add_argument("vm", nargs="?")
    status.add_argument("--json", action="store_true")
    disable = subcommands.add_parser("disable")
    disable.add_argument("vm")
    disable.add_argument("--reason", default="")
    for name in ("enable", "detach", "rotate"):
        item = subcommands.add_parser(name)
        item.add_argument("vm")
    return command


def main():
    args = parser().parse_args()
    try:
        manager = Manager(args.config)
        if args.command == "sync":
            manager.sync()
        elif args.command == "render-bridge":
            count = manager.render_bridge()
            manager.prune_bridge_generations()
            print(f"rendered {count} attachment(s)")
        elif args.command == "status":
            manager.status(args.vm, args.json)
        elif args.command == "disable":
            manager.disable(args.vm, args.reason)
        elif args.command == "enable":
            manager.enable(args.vm)
        elif args.command == "detach":
            manager.detach(args.vm)
        elif args.command == "rotate":
            manager.rotate(args.vm)
    except ManagerError as error:
        print(f"voom-agent-vault: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
