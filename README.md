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

These images use a minimal NixOS configuration with SSH (key-only auth), Fish
shell, and CLI development tools — no GUI, no desktop services.

#### Running VM Images

Additional tooling is provided that makes it easy to build and run VM images:

- [`bake-golden`](./scripts/bake-golden) builds an `.#images.<system>.<format>`
  virtual machine output and copies it to `$VMS_DIR` (default `~/vms`) as
  `golden-<system>.<ext>`, with a per-image `.meta.json` sidecar that records
  relevant image metadata.
- [`vm`](./scripts/vm) orchestrates the VM lifecycle (boot, SSH, teardown,
  etc.), reading the appropriate pre-baked golden image and its sidecar from
  `$VMS_DIR` as necessary.

To start, from the root of this repository, bake (produce) a golden image:

``` bash
./scripts/bake-golden    # (flags: --system x86_64-linux|aarch64-linux, --format qcow|raw)
```

Then, to run and manage virtual machines:

``` bash
vm up scratch            # boot a VM named "scratch"
vm up emacs-test         # boot another VM
vm list                  # show state
vm ssh scratch           # SSH in
vm console scratch       # stream the serial log (live boot output)
vm info scratch          # reprint connection details (ssh/forwards/console)
vm up scratch --rebuild  # wipe disk, reinstall from current golden
vm down scratch          # graceful shutdown
vm rm scratch            # delete VM and all its state
```

`vm up` launches the VM and returns after the hypervisor process starts. It
does not wait for SSH to become reachable; use `vm console <name>` to watch
boot output and `vm ssh <name>` to connect when the guest is ready.

`vm up` flags:

- `--rebuild` — wipe the VM disk and reinstall from the current golden image.

The `vm` command drives two back-ends: qemu + KVM on Linux hosts, and
[vfkit](https://github.com/crc-org/vfkit) (Apple's `Virtualization.framework`)
on Darwin hosts. However, networking is unified via a per-VM
[gvproxy](https://github.com/containers/gvisor-tap-vsock) process. The VM host
always reaches each guest through `localhost:<allocated-port>` (the SSH port is
auto-allocated from 2222–2299 and persisted per VM). SSH binds all interfaces,
so other hosts on your LAN can reach the VM at `<vm-host>:<allocated-port>`
too. Additional service ports are forwarded through gvproxy on demand; see
**Publishing ports** below.

Additional notes:

- The host architecture must match the image architecture in both cases, as
  cross-arch TCG emulation isn't wired up.
- `vm list` shows the effective SSH endpoint in the `SSH` column.
- `bake-golden` defaults to `qcow` on Linux and `raw` on Darwin; the `vm`
  script picks the matching disk extension automatically.
- `vm` is available on the `PATH`, so you can run it from anywhere.
- Per-VM state (disk, port, pidfile, serial log, gvproxy sockets) lives under
  `$VMS_DIR/<name>/`.

##### Publishing ports

By default each VM is reachable on its SSH port, with no other ports exposed.
To expose additional ports (web servers, databases, whatever else is listening
inside the guest), use the `vm expose` / `vm unexpose` / `vm forwards`
subcommands, which manage forwards on a running VM (via gvproxy's HTTP API)
without restarting it:

``` bash
vm expose scratch 8080                   # 0.0.0.0:8080 on the host → guest:8080
vm expose scratch 5432 15432             # remap: host 15432 → guest 5432
vm expose scratch 3000 --bind 127.0.0.1  # loopback-only on the host
vm expose scratch 8080 --auto            # pick a free host port; prints it on stdout
vm forwards scratch                      # list all active forwards
vm unexpose scratch 8080                 # remove the forward
```

Note that `--auto` picks a port in the range 30000–60000 and prints just the
port number on stdout, so `port=$(vm expose scratch 8080 --auto)` works for
scripting purposes.

Forwards are identified by their full `<bind>:<host-port>` tuple, so
`vm unexpose` must be given the same `--bind` that was used at expose time
(e.g., `vm unexpose scratch 3000 --bind 127.0.0.1` to undo the loopback
forward above). `vm forwards <name>` prints the exact local addresses, which
can be copy-pasted back into `vm unexpose`.

Forwards are only managed from the host. The gvproxy forwarder API is exposed
on a unix socket under `$VMS_DIR/<name>/network.sock` (host-side only); there
is no built-in path for processes inside the guest to register their own
forwards.

### Additional Setup

After `nix run .#build-switch` completes on a fresh machine, run
`home-bootstrap` to perform additional setup steps:

``` bash
home-bootstrap
```

The [`home-bootstrap`](./scripts/home-bootstrap) script performs a limited
number of imperative steps, mostly for operations that are awkward to implement
with _home-manager_.

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
architecture. On x86_64 NixOS, the direct equivalents are:

``` bash
sudo nixos-rebuild build --flake .#x86_64-linux
sudo nixos-rebuild switch --flake .#x86_64-linux
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

These checks work on any platform, by forcing full evaluation of each
configuration's module system without building the target derivation.

## References

- https://github.com/dustinlyons/nixos-config
- https://github.com/mitchellh/nixos-config
- https://determinate.systems/posts/nix-direnv/
- https://mitchellh.com/writing/nix-with-dockerfiles

## Thanks

Thanks to [Dustin Lyons's starter
template](https://github.com/dustinlyons/nixos-config), which this
configuration is based off of.
