# mjrusso's NixOS System Configurations

## Setup and Installation

Start by editing [`user-info.nix`](./user-info.nix) to set your desired
username, full name, email address, and SSH public keys.

To prevent local edits to machine-local files from showing up as modifications
(and to prevent committing changes), flag them with the [`skip-worktree`
bit](https://git-scm.com/docs/git-update-index#_skip_worktree_bit) in each
clone:

``` bash
git update-index --skip-worktree user-info.nix
git update-index --skip-worktree host-info.nix
```

_(To verify the flag is set, run `git ls-files -v user-info.nix host-info.nix`;
an `S` prefix means `skip-worktree` is on.)_

To undo (e.g. to pull an upstream change to the template), run the same
command with `--no-skip-worktree`.

For NixOS hosts, keep stable machine identity in `host-info.nix` next to
`user-info.nix`:

``` nix
{
  nixosHostname = "hostname";
  nixosHostId = "1234abcd";
  nixosMainDisk = "/dev/disk/by-id/...";
  nixosExtraHosts = {};
}
```

`nixosHostname` is the machine's NixOS hostname. `nixosHostId` is the
8-hex-character host ID required by ZFS; generate it once and keep it stable
for the life of the pool:

``` bash
head -c 4 /dev/urandom | od -A n -t x1 | tr -d ' '
```

`nixosMainDisk` is the stable `/dev/disk/by-id/...` path of the disk that disko
partitions and installs onto (see the NixOS install section below).
`nixosExtraHosts` is an attribute set of static `/etc/hosts` entries, mapping
an IP address to a list of names, for example `{ "192.168.1.10" = [
"fileserver" ]; }`.

Like `user-info.nix`, this file contains machine-local values and should not be
casually changed after install.

### Mac

Install dependencies:

``` bash
xcode-select --install
```

Next, install Nix using [The Determinate Nix
Installer](https://zero-to-nix.com/concepts/nix-installer).

Then clone this repository, `cd` into the directory, and run the following
command to build and apply changes:

``` bash
nix run .#build-switch
```

Set Fish as the login shell:

``` bash
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells
chsh -s ~/.nix-profile/bin/fish
```

Next, install Homebrew. (Homebrew must be manually installed, as per the
[official installation instructions](https://brew.sh/).) To reduce the number
of moving parts, I'm not using
[nix-homebrew](https://github.com/zhaofengli/nix-homebrew), or
[nix-darwin](https://github.com/LnL7/nix-darwin/)'s Homebrew-related features.

### Linux (non-NixOS)

Install Nix, and then perform a [standalone installation of
home-manager](https://nix-community.github.io/home-manager/index.xhtml#sec-install-standalone):

``` bash
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
nix-shell '<home-manager>' -A install
```

Then clone this repository, `cd` into the directory, and run the following
command to build and apply changes:

``` bash
nix run .#build-switch
```

And set Fish as the login shell:

``` bash
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells
sudo /sbin/usermod -s ~/.nix-profile/bin/fish $USER
```

Finally, reboot the system. (Rebooting is required for terminal definitions to
be properly installed; see `$TERMINFO_DIRS`.)

### NixOS

These instructions install NixOS onto a physical machine, with full-disk ZFS
encryption (via [disko](https://github.com/nix-community/disko)) and
SSH-in-initrd unlock. They assume a single NVMe target disk and a wired
ethernet connection.

#### Boot the installer

Boot the [NixOS minimal installer ISO](https://nixos.org/download/#nixos-iso)
from USB. Use the latest stable release with an LTS kernel to avoid ZFS
incompatibilities. (The installed system can still track `nixos-unstable`; this
is specifically about the installer media.)

At the installer console:

``` bash
sudo -i
ip -br addr show           # confirm wired NIC has a DHCP lease
ping -c2 1.1.1.1           # confirm outbound works
cd /tmp
git clone https://github.com/mjrusso/nixos-config.git
cd nixos-config
```

Identify the target disk and note its stable `by-id` path:

``` bash
lsblk -d -o NAME,SIZE,TYPE
ls -l /dev/disk/by-id/ | grep -v part
```

Then fill in `host-info.nix` and `user-info.nix` per the descriptions at the
top of this file, with `nixosMainDisk` set to the `by-id` path identified
above.

#### Run disko and set ZFS encryption passphrase

Use the command below to run disko:

``` bash
sudo nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- \
  --mode disko --flake .#x86_64-linux
cat /run/zpass             # paste this into disko's prompt
shred -u /run/zpass
```

When prompted, type in a ZFS-encryption passphrase (and store this securely, as
the data is not recoverable without the passphrase).

Disko goes silent for ~1–2 minutes while it creates the GPT, formats the ESP,
builds the pool, applies encryption, and mounts everything under `/mnt`.
Verify:

``` bash
zpool status rpool
zfs list                   # root/home/nix/vms mounted under /mnt
mount | grep /mnt
```

#### Pre-generate SSH host keys (initrd + system)

Both the initrd and the running system need stable ed25519 host keys before
activation. The initrd key defends against first-connect TOFU during the
SSH-in-initrd unlock; the system key does the same for normal SSH.

``` bash
mkdir -p /mnt/etc/secrets/initrd
ssh-keygen -t ed25519 -N "" -f /mnt/etc/secrets/initrd/ssh_host_ed25519_key
chmod 600 /mnt/etc/secrets/initrd/ssh_host_ed25519_key
ssh-keygen -lf /mnt/etc/secrets/initrd/ssh_host_ed25519_key.pub   # record: initrd / port 2222

mkdir -p /mnt/etc/ssh
ssh-keygen -t ed25519 -N "" -f /mnt/etc/ssh/ssh_host_ed25519_key
chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key
ssh-keygen -lf /mnt/etc/ssh/ssh_host_ed25519_key.pub              # record: system / port 22
```

Write both `SHA256:` fingerprints down. You'll verify against them on first
SSH connect (port 2222 for the unlock, port 22 for the running system).

#### Run `nixos-install`

``` bash
nixos-install --flake .#x86_64-linux
```

This builds and copies the system closure onto the new pool. When prompted for
the **root password**, set a long random value. Save it securely alongside the
ZFS passphrase. Then reboot:

``` bash
reboot
```

#### First boot

Every boot requires unlocking the ZFS pool before the system can start. On
first boot, do this at the physical console (keyboard and monitor attached).
The initrd will prompt for the ZFS passphrase on `tty1`; type it there. (The
SSH-in-initrd path below works from the first boot too, but having peripherals
attached for the first one is a useful fallback while verifying the install.)

Once the system is up, find its IP address so you can SSH in:

``` bash
ip -br addr show           # note the address on the wired NIC
ip -br link show           # note the MAC, if you want to set a DHCP reservation
```

This is a good opportunity to create a DHCP reservation (configured on the
router, keyed to that MAC) so the address stays stable across reboots.

#### Set the user password

The user defined by `user-info.nix` is created with `isNormalUser = true` and
authorized SSH keys, but **no password**. That account can't log in at the
console, and `sudo` from it fails because PAM has nothing to authenticate
against. SSH key auth works (the user's keys are installed as authorized keys),
and so does `sudo reboot` (it is declared as `NOPASSWD` in
`security.sudo.extraRules`), but other `sudo` command requires a password.

To set one, SSH in as `root` (the same SSH keys authorize root) and run
`passwd`:

``` bash
ssh root@<box-ip>          # verify the 'system / port 22' fingerprint on first connect
passwd <user>              # the username defined in user-info.nix
```

Generate a long random password and store it in your password manager
alongside the ZFS and root passwords. Since `users.mutableUsers` is `true` by
default, this password persists across `nixos-rebuild`s and is not stored in
the flake.

#### SSH-in-initrd unlock

After the next reboot the box will pause in the initrd waiting for the ZFS
passphrase. From another machine:

``` bash
ssh -t -p 2222 root@<box-ip> systemctl default
```

When SSH prompts about the host key, verify against the **initrd / port 2222**
fingerprint. Type the ZFS passphrase. The connection closes once the real
system continues to boot. After this system finishes booting, you can SSH into
the running system on port 22:

``` bash
ssh <user>@<box-ip>        # verify the 'system / port 22' fingerprint
```

If `systemctl default` doesn't surface the passphrase prompt over your SSH
session, fall back to one of:

``` bash
ssh -t -p 2222 root@<box-ip> 'systemctl default & systemd-tty-ask-password-agent --query'

ssh -p 2222 root@<box-ip>  # at the initrd shell:
zfs load-key rpool
systemctl default
```

#### Tailscale

Physical NixOS hosts enable Tailscale via
[`modules/nixos/tailscale.nix`](./modules/nixos/tailscale.nix). Container and
VM images do not import this module.

The module starts `tailscaled`, installs the `tailscale` CLI, trusts the
`tailscale0` interface in the NixOS firewall, and opens Tailscale's configured
UDP port.

After the first rebuild/switch, authenticate the machine once:

``` bash
sudo tailscale up
```

Open the login URL that command prints, authenticate, and register the machine
in the tailnet. Tailscale stores node state on disk, so later rebuilds and
reboots should not require logging in again.

Useful status checks:

``` bash
tailscale status
tailscale ip
ip link show tailscale0
systemctl status tailscaled
```

To follow Tailscale logs:

``` bash
sudo journalctl -u tailscaled -f
```

#### Syncthing

Physical NixOS hosts enable [Syncthing](https://syncthing.net/) via
[`hosts/nixos/default.nix`](./hosts/nixos/default.nix).

Devices and folders are managed imperatively through Syncthing's web UI.
(`overrideDevices` and `overrideFolders` are set to `false`, so device pairings
and shared folders added through the UI survive a rebuild/switch. Only the
connection options are declarative, per `settings.options`. Note that global
discovery and relays are disabled, so this host syncs only with peers on the
local network.)

The web UI is bound to `127.0.0.1:8384` and is not reachable from other
machines. To access the web UI, forward it over SSH from a machine that has an
accessible browser:

``` bash
ssh -L 8385:localhost:8384 <user>@<host>
```

Then open <http://localhost:8385> in a browser. Substitute the host's Tailscale
name or LAN address for `<host>`; the SSH connection itself can run over
Tailscale.

The forward's local port (`8385` above) must be free on the local machine.
Another host already running Syncthing binds `8384` for its own web UI, so the
tunnel uses a different local port.

To pair this host with another device:

1. In the web UI, note this host's device ID under **Actions → Show ID**
   (or run `journalctl -u syncthing -b | grep "My ID"`).
2. On the other device (via that device's web UI), add this host as a remote
   device using that ID.
3. Back in the web UI, accept the incoming device, then accept or share the
   folders to sync.

Useful checks:

``` bash
systemctl status syncthing
journalctl -u syncthing -b
```

#### Backups

Physical NixOS hosts back up the user's home directory (minus some exceptions)
to a remote target over SFTP using [restic](https://restic.net/). The job is
defined in [`hosts/nixos/default.nix`](./hosts/nixos/default.nix) and driven by
the `nixosBackup` block in [`host-info.nix`](./host-info.nix). Container and VM
images do not enable backups.

``` nix
nixosBackup = {
  enable = true;
  target = "<target>";
  repositoryPath = "<path-on-target>";
};
```

`target` is an SSH destination reachable from this host; add it to
`nixosExtraHosts` if it has no DNS entry. `repositoryPath` is a directory on
the target, and the repository is created inside it under a directory named
after `nixosHostname`, so several hosts can share one target drive without
colliding.

Additional keys:

| Key                    | Default                                        |
|------------------------|------------------------------------------------|
| `targetUser`           | `user` from [`user-info.nix`](./user-info.nix) |
| `passwordFile`         | `/etc/restic/password`                         |
| `identityFile`         | that user's `~/.ssh/id_ed25519_restic`         |
| `voomGuests`           | `false`, see [Voom Guests](#voom-guests)       |
| `voomReadIdentityFile` | that user's `~/.ssh/id_ed25519_voom_read`      |

Setting `enable = false`, or omitting the block, removes the service and its
timer.

##### Initial Setup

1. Generate a dedicated key for the backup and authorize it on the target. The
   timer does not have an agent or a terminal, so this key must **not** have a
   passphrase:

   ``` bash
   ssh-keygen -t ed25519 -N "" -C "restic (unattended)" \
     -f ~/.ssh/id_ed25519_restic
   ```

   Authorize it by adding the public key to `resticKey` in
   [`user-info.nix`](./user-info.nix) and rebuilding the target host. Note that
   the target's configuration confines the key to sftp, and `resticKeySource`
   defines the address it can connect from.

   ``` nix
   resticKey = "ssh-ed25519 AAAA...";
   resticKeySource = "<source>";
   ```

   Verify access from the source to the target:

   ``` bash
   echo quit | env -u SSH_AUTH_SOCK sftp -q -o BatchMode=yes \
     -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_restic <user>@<target>
   ```

2. Create the parent directory on the target. restic creates the repository
   directory itself, but not missing parents:

   ``` bash
   ssh <user>@<target> 'mkdir -p <path-on-target>'
   ```

3. Generate the repository password and install it on this host. _Record it in
   a password manager._

   ``` bash
   pw=$(head -c 32 /dev/urandom | base64)
   printf '%s\n' "$pw"        # copy this into a password manager now
   sudo install -d -m 0755 /etc/restic
   printf '%s\n' "$pw" \
     | sudo install -m 0400 -o <user> /dev/stdin /etc/restic/password
   unset pw
   ```

4. Rebuild, then take the first snapshot by hand rather than waiting for the
   timer. `initialize = true` creates the repository on that first run:

   ``` bash
   nix run .#build-switch
   sudo systemctl start restic-backups-<hostname>.service
   ```

   The first run uploads everything and will take some time; subsequent runs
   send only what has changed, and will complete more quickly.

##### Voom Guests

Setting `voomGuests = true` in the `nixosBackup` block adds a second daily
timer that pulls each running [Voom](https://github.com/mjrusso/voom) guest's
`/home` and Docker volumes into the same repository. (Stopped guests are
skipped.)

Data for each guest is copied to a staging directory that is persisted between
runs. Each is recorded under its own name:

``` bash
restic-<hostname> snapshots --host <guest>
restic-<hostname> restore latest --host <guest> --target /tmp/restore
```

This procedure uses a second key, separate from the repository key. To
configure:

1. Generate the key. As with the repository key, it must have no passphrase:

   ``` bash
   ssh-keygen -t ed25519 -N "" -C "voom read" \
     -f ~/.ssh/id_ed25519_voom_read
   ```

2. Add the public key to `voomReadKey` in [`user-info.nix`](./user-info.nix).
   `voomReadKeySource` is the address a guest sees for a connection originating
   on the host (i.e., gvproxy's gateway).

3. Push the guest configuration, then rebuild this host, in this order.

   ``` bash
   voom-update
   nix run .#build-switch
   ```

To manually trigger a run:

``` bash
sudo systemctl start voom-backup.service
journalctl -u voom-backup.service -b
```

##### Operating and Troubleshooting

Useful checks:

``` bash
systemctl status restic-backups-<hostname>.service
systemctl list-timers restic-backups-<hostname>.timer
journalctl -u restic-backups-<hostname>.service -b
```

Each backup also installs a `restic-<hostname>` wrapper on `PATH` that presets
the repository, the password file, and the SFTP transport, so restic can be
run by hand as the backup user without re-supplying any of them:

``` bash
restic-<hostname> snapshots
restic-<hostname> stats latest
restic-<hostname> check
```

To restore, either into a scratch directory or back over the original paths:

``` bash
restic-<hostname> restore latest --target /tmp/restore
restic-<hostname> restore latest --target / --include <path>
```

#### ZFS Layout Drift

[Disko](https://github.com/nix-community/disko) provisions the pool at install
time only, and contributes no activation scripts or systemd units, so
`build-switch` cannot reconcile the running pool against
[`modules/nixos/disk-config.nix`](./modules/nixos/disk-config.nix). If a
dataset is added or retuned on a live pool (manually via `zfs create`, `zfs
set`, etc.), there is no automated indication that the two disagree.

> [!NOTE]
>
> A dataset declaration generates a `fileSystems` entry, and thus a mount unit.
> The dataset has to exist *before* switching to a configuration that declares
> it, or the mount will fail on switch, and again at every boot.

To compare a pool against what has been declared, list the properties that were
set explicitly rather than inherited:

``` bash
zfs get -r -s local -o name,property,value all <pool>
```

Every line should correspond to an entry in `disk-config.nix`, except for
`nixos:shutdown-time`, which the NixOS ZFS module stamps on the pool.

### Container and VM Images

Container and VM images can be built using
[nixos-generators](https://github.com/nix-community/nixos-generators). The
following formats are supported:

| Format         | Description                             |
|----------------|-----------------------------------------|
| `lxc`          | LXC container tarball                   |
| `lxc-metadata` | LXC metadata tarball (needed for Incus) |
| `docker`       | Docker/OCI image                        |
| `qcow`         | QEMU qcow2 disk image                   |
| `raw`          | Raw disk image                          |
| `iso`          | Bootable ISO image                      |

To build an image:

``` bash
nix build .#images.x86_64-linux.docker
nix build .#images.x86_64-linux.lxc
nix build .#images.aarch64-linux.qcow
```

The resulting image will be written to `./result`.

Note that these images use a minimal NixOS configuration with SSH (key-only
auth), Fish shell, and CLI development tools (and explicitly no GUI or desktop
services). Disk-backed VM images (`qcow` and `raw`) also enable Docker and add
the configured user to the `docker` group. VM guests grant passwordless sudo to
`wheel` so `voom nixos switch` can activate configurations through the normal
user. Images are [voom](https://github.com/mjrusso/voom)-compatible
(`cloud-init` with a `NoCloud` datasource for bootstrap metadata; runtime
coordination via the `voom-control` virtiofs share mounted at `/run/voom`).

#### Running VM Images

Additional tooling is provided that makes it easy to build and run VM images:

- [`bake-golden`](./scripts/bake-golden) builds an `.#images.<system>.<format>`
  virtual machine output and copies it to `$VMS_DIR` (default `~/vms`) as
  `golden-<system>.<ext>`, with a per-image `.meta.json` sidecar that records
  relevant image metadata, including guest capabilities for runtime
  coordination over the `voom-control` share.

- [`voom`](https://github.com/mjrusso/voom) orchestrates the VM lifecycle
  (start, stop, SSH, deletion, etc.).

- [`voom-update`](./scripts/voom-update) brings every running NixOS guest up to
  date with this host: the system configuration, [agent skills](#agent-skills),
  and `~/.emacs.d`.

From the root of this repository, bake (produce) a golden image:

``` bash
./scripts/bake-golden    # (flags: --system x86_64-linux|aarch64-linux, --format qcow|raw)
```

Then import the image, and create/start the VM using Voom, and run the
[`home-bootstrap`](./scripts/home-bootstrap) script:

``` bash
voom image import golden ~/vms/golden-x86_64-linux.qcow2 --meta ~/vms/golden-x86_64-linux.qcow2.meta.json

voom create my-vm --image golden

voom start my-vm

voom ssh my-vm -- home-bootstrap
```

_(In this example, the image is named `golden`, and the VM is named `my-vm`;
both names are arbitrary)._

Later, to rebuild and switch an existing VM in place after changing this flake,
run:

``` bash
voom nixos switch my-vm \
  --flake .#vm-x86_64-linux-qcow \
  -- --sudo
```

The flake target must match the VM guest's architecture and image format. In
normal use the guest architecture matches the host architecture: use
`vm-x86_64-linux-qcow` for an `x86_64` Linux host running a QEMU `qcow` image,
or `vm-aarch64-linux-raw` for an Apple Silicon Darwin host running a vfkit
`raw` image.

To update every NixOS VM at once, use [`voom-update`](./scripts/voom-update):

``` bash
./scripts/voom-update              # all NixOS guests; add --dry-run to preview
./scripts/voom-update my-vm        # or name specific VMs
```

The script runs three phases:

| Phase      | What it does                                                                        |
|------------|-------------------------------------------------------------------------------------|
| `--nixos`  | Rebuilds and switches the guest onto this checkout's configuration.                 |
| `--agents` | Mirrors `~/.agents` into the guest over rsync, then runs `agent-skills-link` there. |
| `--emacs`  | Pulls the guest's `~/.emacs.d` clone (cloning it first if missing).                 |

With no phase flag, all three run. Name one or more to run only the specified
phase(s):

``` bash
./scripts/voom-update --agents            # skills only, every guest
./scripts/voom-update --agents my-vm      # skills only, one guest
./scripts/voom-update --nixos --emacs     # skip the skills mirror
```

Every phase selects VMs the same way: the script ignores guests whose image
doesn't support `nixos switch`, and skips guests that aren't running (with a
warning). The `nixos` phase picks the flake target per VM. It reuses whatever
the guest was last switched to, and otherwise derives the target from the VM's
architecture and image format.

Phases are independent: a failure in one doesn't stop the others, and the
summary names both the VM and the phases that failed (`failed: my-vm(agents)`).

The `agents` phase exists because [agent skills](#agent-skills) are not part of
the flake, and VM guests are not Syncthing peers (only physical hosts run the
service). `agent-skills-link` is installed on a guest only through this flake,
so a guest still on an older configuration will report `has no
agent-skills-link: run the nixos phase first`.

`voom-update` does not push agent *configuration* (credentials, settings,
etc.). See [`agent-config-push`](#agent-configuration).

> [!NOTE]
>
> The `agents` phase is a mirror: it deletes any skill that is in a guest but
> not on this host. Install skills on a physical host, not inside a VM.
>
> The `emacs` phase skips a guest whose `~/.emacs.d` has uncommitted changes,
> and reports that guest as failed. It pulls from
> [the repository](https://github.com/mjrusso/.emacs.d), so unpushed work on
> this host is not pushed to the guests.

> [!NOTE]
>
> vfkit on Darwin requires a `raw` image; baking one directly on Darwin
> requires a Linux builder. The `aarch64-darwin@desktop` host enables
> `nix.linux-builder` (see
> [`hosts/darwin/default.nix`](./hosts/darwin/default.nix)), which spins up a
> small aarch64-linux NixOS VM under vfkit and registers it as a remote
> builder. If the builder is not available on a given host, bake on a host that
> does have an available Linux builder, and rsync the result over:
>
> ``` bash
> # On the host with Linux builder:
> ./scripts/bake-golden --format raw --system aarch64-linux
>
> # From the other host:
> rsync -aS --info=progress2 \
>   <host-with-linux-builder>:~/vms/golden-aarch64-linux.raw{,.meta.json} \
>   ~/vms/
> ```
>
> `rsync -S` preserves sparseness so the copy doesn't allocate the full
> virtual size on the destination.
>
> `--system aarch64-linux` is redundant on aarch64 Linux hosts (bake-golden
> defaults to the host arch). On x86_64 Linux hosts it triggers a cross-arch
> build, which works because
> [`hosts/nixos/default.nix`](./hosts/nixos/default.nix) sets
> `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.

Then, to run and manage virtual machines that use this base image, use the
[Voom](https://github.com/mjrusso/voom) CLI (installed automatically via this
Flake).

#### Publishing VM Web Apps Over Tailscale

The NixOS host can optionally publish Voom HTTP(S) forwards as HTTPS-only
Tailscale subdomains, through Caddy. For example:

``` text
https://<vm>-<guest-port>.voom.example.com
```

To set this up, create a DNS-only wildcard record in Cloudflare for your Voom
publishing domain pointing at the Voom host's Tailscale IP. Do not enable
Cloudflare proxying; the record should resolve directly to the host's Tailscale
address. (This example uses _example.com_; substitute with a real domain that you
control and manage DNS for via Cloudflare.)

For a base domain of `voom.example.com`, create this record in the
`example.com` zone:

``` text
Type: A
Name: *.voom
Content: <tailscale-ip>
Proxy status: DNS only
TTL: Auto
```

Create a Cloudflare token scoped to the relevant domain with `Zone:Zone:Read`
and `Zone:DNS:Edit` permissions, and store the token on the filesystem. The
example below uses `/etc/caddy/cloudflare.env`; avoid `/run` (tmpfs, cleared on
every reboot) unless a secrets manager is wired up to recreate the file on
boot.

``` bash
sudo install -D -m 0600 -o root -g root /dev/null /etc/caddy/cloudflare.env
sudoedit /etc/caddy/cloudflare.env
```

Use the following format for the `cloudflare.env` file:

``` text
CLOUDFLARE_API_TOKEN=...
```

Then update your local `host-info.nix` to enable declarative Caddy publishing:

``` nix
{
  nixosTailnetCaddy = {
    enable = true;

    # Defaults to /etc/caddy/cloudflare.env; set this if you keep the token
    # elsewhere (e.g. a secrets manager's /run/secrets path).
    # cloudflareEnvironmentFile = "/run/secrets/caddy-cloudflare.env";

    # The default is [ ":443" ]. This repo's Tailscale module trusts tailscale0,
    # and this module does not open TCP/443 on non-tailnet interfaces. Set this
    # to an explicit Tailscale address if socket-level binding is preferred.
    # listen = [ "<tailscale-ip>:443" ];

    routes.voom = {
      domain = "voom.example.com";
    };
  };
}
```

The Caddy config is responsible for the wildcard TLS policy, private listener,
and fallback 404. The sync script (`voom-caddy-sync`) replaces the dynamic
route list under the `voom_routes` JSON `@id`. To manually run the sync script:

``` bash
voom-caddy-sync --dry-run
voom-caddy-sync
```

Nix generates one sync command per `nixosTailnetCaddy.routes.<name>` entry,
named after that route's `syncer` (see [Publishing Docker Apps Over
Tailscale](#publishing-docker-apps-over-tailscale) for the other kind). Route
IDs are derived as `<name>_routes`, so `routes.voom` owns `voom_routes`.

The dynamic route list lives only in Caddy's running config, so anything that
(re)loads the declarative config, such as a reboot, `systemctl restart caddy`,
or a `nixos-rebuild` that changes the Caddy config, reseeds it to the empty
state. The `voom-caddy-sync.service` oneshot re-runs the sync on every such
event, so routes self-heal across restarts. Run `voom-caddy-sync` by hand only
when Voom forwards change *without* a Caddy restart (e.g. you start a new VM
app); the service does not watch Voom at runtime.

The default HTTP probe publishes any forward that returns an HTTP response,
including non-2xx statuses such as `401`/`403`/`404` (auth-gated apps, or apps
with no root route). A forward is only skipped if it does not answer within
`--timeout` (default 1 second) or does not speak HTTP at all. Bump `--timeout`
for slow-starting apps, or pass `--all-tcp` to publish every installed non-SSH
TCP forward without probing.

##### Operating and Troubleshooting

Caddy logs to the systemd journal:

``` bash
systemctl status caddy.service
journalctl -u caddy.service -b      # this boot
journalctl -u caddy.service -f      # follow live
```

On first start (and after editing the route domain) Caddy obtains the wildcard
certificate via a Cloudflare DNS-01 challenge; watch the journal for
`certificate obtained successfully`. If the service fails to start with an
`API token '' appears invalid` error, inspect the environment file:

``` bash
sudo cat -A /etc/caddy/cloudflare.env
```

This file must contain exactly `CLOUDFLARE_API_TOKEN=<token>`. Note that
systemd's `EnvironmentFile` does not strip quotes (`CLOUDFLARE_API_TOKEN="..."`
passes the quotes through to Caddy), so write the token bare. `cat -A` surfaces
stray quotes, trailing whitespace, or `^M` (CRLF) line endings. After fixing
the file, run:


``` bash
sudo systemctl restart caddy.service
```

Confirm the seeded route target exists before syncing. This command should
return an empty list (`[]`), until the first successful sync:

``` bash
curl -s localhost:2019/id/voom_routes/routes | jq
```

To sync and reach a published app from a machine on the tailnet:

``` bash
voom-caddy-sync --dry-run    # preview the routes without patching Caddy
voom-caddy-sync
curl -v https://<vm>-<guest-port>.voom.example.com/
```

A `no voom route` 404 served with a *valid* certificate means the request
matched the wildcard, but the per-app route is not defined. Re-run the sync
(also run `systemctl status voom-caddy-sync.service`), and check the synced
routes:

``` bash
curl -s localhost:2019/id/voom_routes/routes | jq 'length'
```

If a published host is unreachable from another tailnet machine while working
locally, the problem is likely client-side routing. Because the published names
resolve to a Tailscale IP (`100.64.0.0/10`), a VPN or other overlay on the
client that claims that CGNAT range can hijack the route. (`tailscale ping`
bypasses the OS routing table, but `curl` will likely fail fast with
`connection refused`.) Confirm with `route -n get <ip>` (MacOS) or `ip route
get <ip>` (Linux); if it's a client-side routing issue, disconnect from VPN or
exclude `100.64.0.0/10` from its routes.

#### Publishing Docker Apps Over Tailscale

The same Caddy instance can publish local Docker containers as HTTPS-only
Tailscale subdomains, driven entirely by container labels:

``` text
https://<caddy.host>.homelab.example.com
```

_(Unlike the Voom route, a watcher re-syncs on every container start and stop;
no manual sync step is necessary.)_

This reuses the Cloudflare token and environment file described in [Publishing
VM Web Apps Over Tailscale](#publishing-vm-web-apps-over-tailscale), with a
single token covering both routes, provided that both domains live in the same
zone. This requires a second DNS-only wildcard record; for example, for a base
domain of `homelab.example.com`:

``` text
Type: A
Name: *.lab
Content: <tailscale-ip>
Proxy status: DNS only
TTL: Auto
```

Next, add a route with `syncer = "docker"` to your local `host-info.nix`:

``` nix
{
  nixosTailnetCaddy = {
    enable = true;

    routes.voom = {
      domain = "voom.example.com";
    };

    routes.homelab = {
      domain = "homelab.example.com";
      syncer = "docker";
    };
  };
}
```

`syncer = "voom"` (the default) publishes Voom forwards, `syncer = "docker"`
publishes Docker containers, and `syncer = "none"` generates no syncer (leaving
the route empty/available for ad-hoc `PATCH`es).

The Docker/ Compose stack does not need to be aware of the published domain.
Compose files can live anywhere, with containers opting in with labels:

``` yaml
services:
  app1:
    image: traefik/whoami
    ports:
      - "127.0.0.1:8080:80"
    labels:
      - caddy.host=app1
    restart: unless-stopped
```

| Label                | Description                                                                                                                   |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `caddy.host`         | Required. Comma-separated names; publishes the container at `<name>.<domain>` for each. Each name must be a single DNS label. |
| `caddy.upstream`     | Dial address override. Defaults to the container's lowest `127.0.0.1` published port.                                         |
| `caddy.csp`          | `Content-Security-Policy` to set on responses.                                                                                |
| `caddy.csp-paths`    | Comma-separated Caddy path matchers limiting where `caddy.csp` applies. Defaults to every path.                               |
| `caddy.paths`        | Comma-separated Caddy path matchers; anything outside them gets a 404. Defaults to serving all.                               |
| `caddy.rewrite-from` | Request path to rewrite. Requires `caddy.rewrite-to`.                                                                         |
| `caddy.rewrite-to`   | Upstream URI to rewrite it to. Requires `caddy.rewrite-from`.                                                                 |

Publishing is strictly opt-in: containers without a `caddy.host` label are
never routed. Containers that do not publish a `127.0.0.1` port and don't set
`caddy.upstream` are also skipped. If a `caddy.host` name is not a usable DNS
label, that name is skipped with a warning in the journal; the container's other
names are unaffected. Setting only one half of a rewrite is likewise reported in
the journal, and the rewrite is dropped.

A container claiming several names is published at each of them, all dialling
the same upstream. Every label except `caddy.host` may be suffixed with
`.<name>` to apply to one of those names only, and the suffixed value wins where
both are set. One app can therefore expose a small surface on one hostname and
its full interface on another:

``` yaml
    labels:
      - caddy.host=app1,app1-admin
      # Sandbox user-supplied content wherever it is served from...
      - caddy.csp=sandbox allow-scripts
      - "caddy.csp-paths=/files/*"
      # ...but only app1-admin serves anything beyond it.
      - "caddy.paths.app1=/files/*,/upload"
      # A friendly path for an upstream endpoint that needs a token in its URI.
      - caddy.rewrite-from.app1=/upload
      - caddy.rewrite-to.app1=/api/guest/SOME_TOKEN
```

Per name, the stages run in this order: the `caddy.paths` gate, then the
`caddy.csp` header, then the rewrite, then the proxy.

Discovery is daemon-wide (`docker ps --filter label=caddy.host`), not tied to
any particular Compose project or directory, so apps can be spread across as
many Compose files as convenient. `caddy.host` values are therefore a
_host-wide_ namespace: if two containers claim the same name, the sync logs
which containers collided and which upstream won, then publishes one of them.
The winner is chosen by ordering on the dial address, so it does not change
from sync to sync.

This is implemented with two systemd units:

- `docker-caddy-sync-<name>.service` is a oneshot bound to Caddy, re-seeding
  the routes whenever Caddy starts or restarts (as with Voom, the dynamic route
  list does not survive a restart).
- `docker-caddy-sync-<name>-watch.service` follows `docker events` and re-syncs
  on container start and stop.

##### Operating and Troubleshooting

The sync command is on `PATH`, and can be run manually:

``` bash
docker-caddy-sync-homelab --dry-run   # preview routes without patching Caddy
docker-caddy-sync-homelab
```

``` bash
systemctl status docker-caddy-sync-homelab.service
journalctl -u docker-caddy-sync-homelab-watch.service -f
curl -s localhost:2019/id/homelab_routes/routes | jq
```

### Additional Setup

After `nix run .#build-switch` completes on a fresh machine, run
`home-bootstrap` to perform additional setup steps:

``` bash
home-bootstrap
```

The [`home-bootstrap`](./scripts/home-bootstrap) script performs a limited
number of imperative steps, mostly for operations that are awkward to implement
with _home-manager_.

#### SSH Key Passphrase

`~/.ssh/config` is managed by _home-manager_, as per
[`modules/shared/config/ssh.nix`](./modules/shared/config/ssh.nix). The
configuration sets `AddKeysToAgent yes`, loading the key into `ssh-agent` on
first use rather than re-prompting for the passphrase on every connection.

On MacOS, the `UseKeychain yes` option is also set, allowing SSH to read the
passphrase from the system Keychain automatically. To enable, run the following
on each host:

``` bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

On NixOS, `programs.ssh.startAgent` (see
[`hosts/nixos/default.nix`](./hosts/nixos/default.nix)) runs `ssh-agent` as a
per-user `systemd` service. The agent starts empty and holds the key for the
life of the user's `systemd` instance. Expect to enter the passphrase once per
fresh `ssh-agent` lifetime, usually after the first login that starts the
user's `systemd` manager; this also applies over SSH. Multiple concurrent
logins share the same agent. (To instead cache it until reboot, set
`users.users.<user>.linger = true` so the agent survives between logins.)

#### Fonts

I use [Berkeley Mono](https://berkeleygraphics.com/typefaces/berkeley-mono/),
which must be manually installed.

#### Emacs

Emacs is installed via Nix, using a custom build
([mjrusso/emacs-flake](https://github.com/mjrusso/emacs-flake)).

This flake is automatically built and
[cached](https://garnix.io/docs/ci/caching/) by [Garnix](https://garnix.io/).

- Garnix's binary cache is configured automatically for Darwin and NixOS hosts
  (see [modules/shared/caches/](./modules/shared/caches)).

  - However, on first run, the caches module will not have been activated yet.
    Bootstrap by exporting `NIX_CONFIG` for the initial `build-switch` (note
    that once that switch completes, `/etc/nix/nix.conf` should contain the
    Garnix-related entries, so the manual override will no longer be needed):

      ``` bash
      export NIX_CONFIG='extra-substituters = https://cache.garnix.io
      extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g='
      nix run .#build-switch
      ```

- For Linux (non-NixOS) hosts, the Garnix cache must be configured manually.
  _(See [Garnix's documentation](https://garnix.io/docs/ci/caching/#caching).)_
  Add the following to `/etc/nix/nix.conf` (or `~/.config/nix/nix.conf` if your
  user is trusted):

    ```
    extra-substituters = https://cache.garnix.io
    extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=
    ```

To verify the Garnix substituter is active on the current machine:

``` bash
nix config show substituters | grep garnix
nix config show trusted-public-keys | grep garnix
```

If nothing matches, Nix won't query Garnix, and any build that depends on a
pre-built artifact there (such as Emacs) will fall through to building from source.

Note that my [Emacs configuration](https://github.com/mjrusso/.emacs.d) is not
part of this repository (and not managed by _home-manager_). It is cloned into
`~/.emacs.d` automatically by the [`home-bootstrap`](./scripts/home-bootstrap)
script, or can alternatively be cloned directly:

``` bash
git clone https://github.com/mjrusso/.emacs.d ~/.emacs.d
```

#### Agent Skills

Global agent skills live in `~/.agents/skills/`, installed with `npx skills add
<source> -g`. Each agent has its own skills directory, with one symlink per
skill:

``` text
~/.claude/skills/<name>   ->   ~/.agents/skills/<name>
~/.codex/skills/<name>    ->   ~/.agents/skills/<name>
```

[Syncthing](#syncthing) syncs `~/.agents/` between physical hosts, so every
machine gets the same skills. It does not create the symlinks, which live
outside `~/.agents/` and differ per machine. Create them with
[`agent-skills-link`](./scripts/agent-skills-link), on every machine, after
installing a skill:

``` bash
agent-skills-link --dry-run    # report what would change
agent-skills-link
```

The script is idempotent. It removes a symlink only when that symlink points
into `~/.agents/skills/` and its target is no longer a skill, so
`~/.codex/skills/.system` and anything else in an agent's directory survives.
It exits non-zero if a real file or directory blocked a skill from being
linked.

A skill is any subdirectory of `~/.agents/skills/` that holds a `SKILL.md`.

Skills can be added manually:

``` bash
mkdir -p ~/.agents/skills/my-skill
$EDITOR ~/.agents/skills/my-skill/SKILL.md
agent-skills-link
```

...or from a git repository via `npx skills add ...`.

To push skills to VM guests, see the `--agents` phase of
[`voom-update`](#running-vm-images).

#### Agent Configuration

The [`agent-config-push`](./scripts/agent-config-push) script copies a subset
of agent-specific configuration to other machines over SSH:

``` bash
agent-config-push --dry-run --voom myvm                 # report what would change
agent-config-push --voom myvm --voom myvm2 user@myhost
```

Each `--voom` flag specifies one Voom-powered VM. Bare arguments are SSH
destinations. See `agent-config-push --help` for additional details.

| Pushed                                          | Notes                                                 |
|-------------------------------------------------|-------------------------------------------------------|
| `.claude/.credentials.json`, `.codex/auth.json` | OAuth tokens, mode `0600`. Pushed unless `--no-auth`. |
| `.claude/CLAUDE.md`, `.codex/AGENTS.md`         | Global instructions, if present.                      |
| `.claude/statusline-command.sh`                 | Status line script, if present.                       |
| `.claude/settings.json`                         | Merged, not copied. Pushed unless `--no-config`.      |
| `.codex/config.toml`                            | Merged, not copied. Pushed unless `--no-config`.      |

Skills, custom agents, commands, and per-machine state are never pushed.

`settings.json` and `config.toml` are merged, not replaced: only a subset of
keys are sent.

> [!NOTE]
>
> This copies live OAuth tokens; every destination gains full access to those
> accounts. Push only to machines you control.
>
> Tokens are copied, not shared: a refresh on one machine can invalidate
> another's copy. Re-run the script if a guest reports an expired session.
>
> On MacOS, Claude Code keeps credentials in the Keychain, so
> `.credentials.json` does not exist there. Push from a Linux host.

## Usage

_(These commands must be executed from the directory that this repo has been
cloned to.)_

To build (without applying changes):

``` bash
nix run .#build
```

To build **and** apply changes:

``` bash
nix run .#build-switch
```

Both commands are flake apps that call the shared [`apps/run`](./apps/run)
dispatcher. The dispatcher maps `build` to a build-only action and
`build-switch` to a switch action, then chooses the right backend for the
current platform.

On NixOS, it detects `/etc/NIXOS` and calls `nixos-rebuild` for the current
architecture. In one of this repo's VM guests, it selects the matching
`vm-<system>-<format>` configuration instead. On x86_64 NixOS, the direct
equivalents are:

``` bash
nixos-rebuild build --flake .#x86_64-linux
nixos-rebuild switch --sudo --flake .#x86_64-linux
```

Inside an x86_64 qcow VM guest, the direct equivalents are:

``` bash
nixos-rebuild build --flake .#vm-x86_64-linux-qcow
nixos-rebuild switch --sudo --flake .#vm-x86_64-linux-qcow
```

On non-NixOS Linux, the dispatcher calls standalone `home-manager` instead:

``` bash
home-manager build --flake .#x86_64-linux
home-manager switch --flake .#x86_64-linux
```

On Darwin, it selects the `aarch64-darwin@desktop`, `@laptop`, or `@vm`
configuration from `system_profiler`, builds
`darwinConfigurations.<system>.system`, and `build-switch` then runs
`darwin-rebuild switch` from the build result.

> [!NOTE]
>
> Only files in the working tree will be copied to the [Nix
> Store](https://zero-to-nix.com/concepts/nix-store). Ensure that any new files
> have been added to the working tree (use `git add`) before running
> `nix run .#build` or `nix run .#build-switch`, or they will be ignored. (The
> files do not need to be committed to the repo.)

### Updating dependencies

To update dependencies, run:

``` bash
nix flake update
```

### Garbage collection

Every `build-switch` leaves the previous build behind as an older generation,
and the Nix store accumulates unreferenced paths over time. To reclaim that
space, use [`nh`](https://github.com/nix-community/nh):

``` bash
nh clean all
```

`nh clean all` works in two phases. First, it scans every profile it can find
(NixOS system profile, per-user profiles, home-manager generations), removing
old generations that fall outside of its keep policy. It then runs a store
garbage collection, freeing the paths those generations were keeping alive.

To preview what would be removed before committing to it:

``` bash
nh clean all --dry
```

By default `nh clean all` keeps the 1 most recent generation and anything from
the last 0 days; loosen that to avoid throwing away generations you might want
to roll back to:

``` bash
nh clean all --keep 5 --keep-since 7d
```

`--keep` sets how many recent generations to retain per profile, and
`--keep-since` retains anything newer than the given age regardless of count.

### Checks

To verify that all configurations (Darwin, NixOS, home-manager, and
container/VM images) evaluate without errors:

``` bash
nix flake check --show-trace --print-build-logs
```

Examples of how to run a single check:

``` bash
nix build .#checks.aarch64-darwin.darwin-aarch64-darwin@desktop
nix build .#checks.aarch64-darwin.nixos-x86_64-linux
nix build .#checks.aarch64-darwin.image-x86_64-linux-docker
```

Each check forces full evaluation of a configuration's module system without
building the target derivation, so most of them run on any platform. The Darwin
checks are the exception: they need a Darwin builder.

## References

- https://github.com/dustinlyons/nixos-config
- https://github.com/mitchellh/nixos-config
- https://determinate.systems/posts/nix-direnv/
- https://mitchellh.com/writing/nix-with-dockerfiles

## Thanks

Thanks to [Dustin Lyons's starter
template](https://github.com/dustinlyons/nixos-config), which this
configuration is based off of.
