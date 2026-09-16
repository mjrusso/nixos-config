# mjrusso's NixOS System Configurations

This shared repository contains the modules and tools for my systems. I keep
user- and host-specific values in a separate system configuration repository,
which consumes the shared flake.

The shared flake exports the following constructors under `lib`:

- `mkDarwinConfiguration`
- `mkNixosConfiguration`
- `mkHomeConfiguration`
- `mkWslConfiguration`
- `mkVmConfiguration`
- `mkImage`

Each constructor wires the inputs and modules from the shared repository. Each
accepts `userInfo` and, where applicable, `hostInfo`. The constructors also
accept `extraModules`, `extraHomeModules`, and `extraSpecialArgs` for local
extensions.

## Setup and Installation

### Create a system configuration repository

Create a Git repository from the included template:

``` bash
mkdir my-system-config
cd my-system-config
git init
nix flake init -t github:mjrusso/nixos-config#system-config
```

The generated `flake.nix` uses `github:mjrusso/nixos-config` as an input and
re-exports its apps. It also creates Darwin, NixOS, standalone Home Manager,
VM, image, and check outputs. Remove outputs you do not need, or use the extra
module arguments above to extend them.

At its simplest, the system configuration flake uses this input and
constructor:

``` nix
inputs.nixos-config.url = "github:mjrusso/nixos-config";

outputs = { nixos-config, ... }: {
  nixosConfigurations.x86_64-linux =
    nixos-config.lib.mkNixosConfiguration {
      system = "x86_64-linux";
      userInfo = import ./user-info.nix;
      hostInfo = import ./host-info.nix;
    };
};
```

The template repeats this pattern for all supported output types.

Edit the generated `user-info.nix` with your username, name, email address,
and SSH public keys. For a physical NixOS host, edit `host-info.nix`:

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

This file contains stable machine identity and should not be casually changed
after installation. Commit the configuration files normally. Use a private
repository if you do not want to publish them.

Add the generated files before evaluating the system configuration flake. Then
create and commit its lock file:

``` bash
git add flake.nix user-info.nix host-info.nix .gitignore
nix flake lock
git add flake.lock
git commit -m "Initialize system configuration"
```

Unless a section says otherwise, run the commands below from the system
configuration repository. To test unpublished changes in a sibling checkout
of the shared repository, override the input:

``` bash
nix run .#build --override-input nixos-config path:../nixos-config
nix flake check --override-input nixos-config path:../nixos-config
```

### Mac

Install dependencies:

``` bash
xcode-select --install
```

Next, install Nix using [The Determinate Nix
Installer](https://zero-to-nix.com/concepts/nix-installer).

Then clone your system configuration repository, `cd` into it, and build and
apply the configuration:

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

Then clone your system configuration repository, `cd` into it, and build and
apply the configuration:

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

### Windows 11 with NixOS-WSL

#### Install WSL and NixOS-WSL

From the Windows host, install (or update) NVIDIA's Windows driver normally.
(The Game Ready and Studio drivers both include WSL CUDA support.) In a regular
PowerShell window, verify the Windows driver:

``` powershell
nvidia-smi
```

Open PowerShell as an administrator. If WSL is not installed, run the first
command below and restart Windows when prompted. Then open another
administrator PowerShell window and run the remaining commands. WSL version
2.4.4 or newer is required.

``` powershell
wsl --install --no-distribution
wsl --update
wsl --version
```

Download the latest `nixos.wsl` file from [the NixOS-WSL installation
page](https://nix-community.github.io/NixOS-WSL/install.html). In PowerShell,
change to the directory that contains the file. Install the distribution,
confirm that it uses WSL 2, and open it:

``` powershell
wsl --install --from-file .\nixos.wsl --name NixOS
wsl --list --verbose
wsl -d NixOS
```

The last command opens a shell inside NixOS-WSL as the initial `nixos` user.

#### Apply the system configuration

Run the commands in this section inside NixOS-WSL. Clone your system
configuration repository into the WSL filesystem and `cd` into it. Configure
repository access for the initial `nixos` user first if the repository is
private.

Update the repository's `nixos-config` flake input, then build and apply the
WSL configuration:

``` bash
nix --extra-experimental-features 'nix-command flakes' \
  flake update nixos-config
nix --extra-experimental-features 'nix-command flakes' run .#build-switch
```

The applied configuration enables `nix-command` and flakes, so later runs can
use the shorter `nix run .#build-switch` command.

The initial NixOS-WSL user is named `nixos`. If `user-info.nix` selects a
different username, the command builds the configuration and prints the
PowerShell commands needed to activate it. Run the printed commands in
PowerShell. They stop NixOS-WSL and initialize the configured user. After the
commands finish, reopen the distribution:

``` powershell
wsl -d NixOS
```

The checkout remains in the initial user's home directory. In the new WSL
shell, move it into the configured user's home directory and change its
ownership, or clone it again. Then `cd` into the checkout and apply the
configuration a second time:

``` bash
nix run .#build-switch
```

#### Verify GPU access

The WSL configuration enables the Windows GPU driver and installs the
CUDA-enabled Nixpkgs build of Blender from the Nix community CUDA cache.
Verify the GPU after applying the configuration:

``` bash
nvidia-smi
```

The `nvidia-smi` command is a wrapper around
`/usr/lib/wsl/lib/nvidia-smi`, so it also works in noninteractive SSH
sessions. Confirm that Blender detects the OptiX device:

``` bash
blender --background --python-expr '
import bpy
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "OPTIX"
prefs.get_devices()
print([(device.name, device.type) for device in prefs.devices])
'
```

For an RTX GPU, render a Cycles scene with OptiX:

``` bash
blender -b scene.blend -o //renders/frame_ -f 1 -- --cycles-device OPTIX
```

The scene must use Cycles. Keep source trees and render scratch data in the
WSL filesystem. Windows drive automount is disabled by this configuration, so
transfer inputs and outputs over SSH rather than through `/mnt/c`.

#### Remote access through the Windows Tailscale host

Run Tailscale and OpenSSH on Windows. Windows is the tailnet node and recovery
path. Tailscale does not need to run inside WSL. The WSL SSH server listens on
port 2222 with key-only authentication and does not permit root login. It also
disables agent forwarding, TCP forwarding, tunnels, and X11 forwarding.

Install [Tailscale for Windows](https://tailscale.com/download/windows), sign
in, and configure it to start automatically. Limit access to Windows port 22
with the tailnet policy and the Windows Firewall rule below.

If the Windows OpenSSH server is not installed, run the following from an
administrator PowerShell:

``` powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

The OpenSSH installation normally creates the `OpenSSH-Server-In-TCP`
firewall rule. Verify that it exists and restrict its source addresses to the
Tailscale ranges:

``` powershell
if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
    -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule `
    -Name "OpenSSH-Server-In-TCP" `
    -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort 22
}
Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
  -RemoteAddress "100.64.0.0/10","fd7a:115c:a1e0::/48"
```

This rule permits SSH through Tailscale addresses and blocks direct LAN and
internet access to port 22. If the host needs another approved management
network, add its subnet to `-RemoteAddress`.

Add the client public key to the Windows SSH account. For a standard Windows
account, place it on one line in:

``` text
C:\Users\<windows-user>\.ssh\authorized_keys
```

For a Windows account in the Administrators group, the default OpenSSH server
configuration instead uses:

``` text
C:\ProgramData\ssh\administrators_authorized_keys
```

Restrict the administrators key file to Administrators and SYSTEM from an
administrator PowerShell:

``` powershell
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys `
  /grant "Administrators:F" /grant "SYSTEM:F"
```

Edit `C:\ProgramData\ssh\sshd_config` and set these global options before any
`Match` block:

``` sshconfig
PubkeyAuthentication yes
PasswordAuthentication no
AllowTcpForwarding yes
```

Validate the configuration and restart the service after changing the file:

``` powershell
& "$env:WINDIR\System32\OpenSSH\sshd.exe" -t
Restart-Service sshd
```

See Microsoft's [OpenSSH server configuration
reference](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
for the configuration and authorized-key file locations.

Test this layer from the client before configuring the WSL jump:

``` bash
ssh windows-user@windows-host.your-tailnet.ts.net
```

Configure the client with Windows as an SSH jump host:

``` sshconfig
Host windows-host
    HostName windows-host.your-tailnet.ts.net
    User windows-user

Host windows-wsl
    HostName localhost
    Port 2222
    User linux-user
    ProxyJump windows-host
```

Replace the hostnames and usernames with their actual values. Inside WSL,
check the SSH service and listener:

``` bash
systemctl status sshd
ss -tlnp | grep 2222
```

From Windows PowerShell:

``` powershell
Test-NetConnection localhost -Port 2222
```

Windows OpenSSH must permit TCP forwarding because `ProxyJump` uses a
`direct-tcpip` channel. Connect from the client:

``` bash
ssh windows-wsl
```

The connection uses WSL's default NAT and Windows localhost forwarding. It
does not need Tailscale Serve, mirrored networking, or a `portproxy` rule.
If WSL stops, connect to Windows:

``` bash
ssh windows-host
```

Then start WSL from the Windows SSH session:

``` powershell
wsl -d NixOS
```

For unattended availability after a Windows restart, create a Windows
Scheduled Task under the Windows account that owns the WSL distribution. Use
an "At log on" trigger for that account and configure these values:

``` text
Program:   C:\Windows\System32\wsl.exe
Arguments: -d NixOS --user root --exec /run/current-system/sw/bin/sleep infinity
```

Replace `NixOS` with the name shown by `wsl --list --verbose`. Set the task to
restart on failure and disable its execution time limit. The persistent
process prevents WSL from stopping while systemd manages `sshd`. The task does
not run until the Windows user signs in. Before that login, use Windows SSH to
start WSL manually.

#### Security and operation

WSL 2 runs a Linux kernel in a Microsoft-managed utility VM, but its default
configuration is not a strong isolation boundary from the Windows user. WSL
can access Windows drives under `/mnt`, run Windows executables, reach Windows
network services, and use the host GPU. Use a separate conventional VM or
remote sandbox for untrusted repositories or highly autonomous agents.

This WSL configuration disables automatic Windows drive mounts and Windows
executable interoperability. These restrictions do not affect the Windows SSH
jump host, scheduled startup, or GPU access. The configured user remains a
member of `wheel`, a trusted Nix user, and able to use `sudo`. Treat access to
that account as root access within WSL, and use it only for trusted or reviewed
workloads.

For normal development, keep credentials scoped, do not expose SSH through an
internet router, and keep Windows, WSL, Tailscale, and the NVIDIA driver
updated. Back up important WSL state (e.g. with `wsl --export`).

#### Troubleshooting

WSL 2 requires hardware virtualization. If Windows reports
`HCS_E_HYPERV_NOT_INSTALLED`, enable virtualization in the machine firmware.
The setting is commonly called SVM on AMD systems and Intel Virtualization
Technology or VT-x on Intel systems.

If the Windows SSH connection works but `ssh windows-wsl` fails, check the WSL
Scheduled Task, `systemctl status sshd`, the port 2222 listener, Windows
localhost connectivity, and Windows OpenSSH TCP forwarding in that order.

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
git clone <your-configuration-repository-url> system-config
cd system-config
```

For a private repository, authenticate Git in the installer environment before
cloning it.

Identify the target disk and note its stable `by-id` path:

``` bash
lsblk -d -o NAME,SIZE,TYPE
ls -l /dev/disk/by-id/ | grep -v part
```

Confirm `host-info.nix` and `user-info.nix` contain the intended values, with
`nixosMainDisk` set to the `by-id` path identified above.

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
the system configuration flake.

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
the `nixosBackup` block in your system configuration repository's
`host-info.nix`. Container and VM images do not enable backups.

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

| Key                    | Default                                                     |
|------------------------|-------------------------------------------------------------|
| `targetUser`           | `user` from your system configuration repository's `user-info.nix` |
| `passwordFile`         | `/etc/restic/password`                                      |
| `identityFile`         | that user's `~/.ssh/id_ed25519_restic`                      |
| `voomGuests`           | `false`, see [Voom Guests](#voom-guests)                    |
| `voomReadIdentityFile` | that user's `~/.ssh/id_ed25519_voom_read`                   |

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

   Authorize it by adding the public key to `resticKey` in your system
   configuration repository's `user-info.nix`, then rebuild the target host.
   The target's configuration confines the key to sftp, and
   `resticKeySource` defines the address it can connect from.

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

2. Add the public key to `voomReadKey` in your system configuration
   repository's `user-info.nix`. `voomReadKeySource` is the address a guest
   sees for a connection originating on the host (i.e., gvproxy's gateway).

3. Push the guest configuration, then rebuild this host, in this order.

   ``` bash
   nix run .#voom-update
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
  date with this host: the system configuration and `~/.emacs.d`.

From the system configuration repository, bake (produce) a golden image:

``` bash
nix run .#bake-golden
# Optional flags: --system x86_64-linux|aarch64-linux, --format qcow|raw
```

Then import the image and create the VM:

``` bash
voom image import golden ~/vms/golden-x86_64-linux.qcow2 --meta ~/vms/golden-x86_64-linux.qcow2.meta.json

voom create my-vm --image golden
```

If the host uses Agent Vault, complete [Attach a New VM](#attach-a-new-vm)
before you start the VM. A first attachment requires a stopped VM. Otherwise,
start the VM immediately. After the first start, run the
[`home-bootstrap`](./scripts/home-bootstrap) script:

``` bash
voom start my-vm

voom ssh my-vm -- home-bootstrap
```

_(In this example, the image is named `golden`, and the VM is named `my-vm`;
both names are arbitrary)._

Later, to rebuild and switch an existing VM in place after changing the system
configuration flake, run:

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

To update every NixOS VM at once, run the exported `voom-update` app:

``` bash
nix run .#voom-update                            # all guests
nix run .#voom-update -- --dry-run               # preview
nix run .#voom-update -- my-vm                   # specific VMs
```

The NixOS phase uses the system configuration flake in the current directory.
To run it from another directory, pass the configuration path to both commands:

``` bash
nix run /path/to/system-config#voom-update -- --flake /path/to/system-config
```

The script runs two phases:

| Phase     | What it does                                                            |
|-----------|-------------------------------------------------------------------------|
| `--nixos` | Rebuilds and switches the guest onto the system configuration checkout. |
| `--emacs` | Pulls the guest's `~/.emacs.d` clone (cloning it first if missing).     |

With no phase flag, both phases run. Name one or more to run only the specified
phase(s):

``` bash
nix run .#voom-update -- --nixos
nix run .#voom-update -- --emacs my-vm
```

Every phase selects VMs the same way: the script ignores guests whose image
doesn't support `nixos switch`, and skips guests that aren't running (with a
warning). The `nixos` phase picks the flake target per VM. It reuses whatever
the guest was last switched to, and otherwise derives the target from the VM's
architecture and image format.

Phases are independent: a failure in one doesn't stop the others, and the
summary names both the VM and the phases that failed (`failed: my-vm(emacs)`).

> [!NOTE]
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
> nix run .#bake-golden -- --format raw --system aarch64-linux
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
[Voom](https://github.com/mjrusso/voom) CLI. The system configuration installs
it automatically.

#### Voom Agent Vault

[Agent Vault](https://docs.agent-vault.dev/) is an open-source credential vault
and HTTP/HTTPS proxy. Agent Vault stores credentials on the host and adds them
to outbound requests that match configured services. Voom guests send requests
through the proxy without storing the actual credentials.

The `services.voomAgentVault` module runs one Agent Vault instance for all Voom
VMs on a host. The manager creates one Agent Vault agent and token for each
assigned VM. The token stays on the host and grants access to one exact vault.

HAProxy listens on a separate host Unix socket for each VM. Voom attaches that
socket to the VM, and HAProxy adds the VM's token to requests from the socket.
The manager binds the attachment to the VM's immutable ID. The VM name selects
the desired vault from Nix configuration.

Solid arrows show request traffic. Dashed arrows show configuration performed
by `voom-agent-vault sync`.

``` mermaid
flowchart LR
    subgraph Guest["Voom guest"]
        C["Command"]
        W["voom-egress-run<br/>sets proxy and CA variables"]
        C --> W
    end

    subgraph Host["Trusted host"]
        N["Nix assignment<br/>VM name to vault"]
        M["voom-agent-vault sync<br/>binds immutable VM ID"]
        G["gvproxy<br/>per-VM egress route"]
        H["HAProxy<br/>per-VM Unix socket"]
        T["Host-only Agent Vault token"]
        A["Agent Vault proxy<br/>default 127.0.0.1:14322"]

        G --> H
        T -.->|"token map"| H
        H --> A
    end

    API["External API"]

    W -->|"HTTP(S) proxy<br/>192.168.127.1:3128"| G
    A -->|"injects service credential"| API
    N -.-> M
    M -.->|"configures route"| G
    M -.->|"renders socket"| H
    M -.->|"stores token"| T
    M -.->|"creates agent and exact grant"| A
```

For the lower-level attachment interface and recovery behavior, see Voom's
[egress proxy integration](https://github.com/mjrusso/voom/blob/86ce68f9861ed761650be26f3a1e7aca0779f4b3/README.md#egress-proxy-integration).

> [!IMPORTANT]
>
> Explicit mode does not block direct guest networking or remove existing
> guest credentials. After you validate brokered access, remove each
> guest-held credential. Access to that credential then depends on the proxy.

The shared repository defines this module, but it does not assign VMs. Put the
module settings and exact VM-to-vault mappings in a host-specific module in
your system configuration repository:

``` nix
services.voomAgentVault = {
  enable = true;
  user = userInfo.user;
  assignments = {
    development = "development";
    personal = "personal";
  };
};
```

The attribute name is the exact Voom VM name. The value is the exact Agent
Vault vault name. A changed mapping is a profile change. A removed mapping is
a detach request on the next authenticated synchronization.

Before you apply the system configuration, inspect the host resolver:

``` bash
awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf
ip route get <resolver-address>
```

If a resolver route starts with `local`, add its exact address to
`services.voomAgentVault.localDNSAddresses`. The module permits only TCP and
UDP port 53 to those addresses. Agent Vault refuses to start when it detects
an unlisted host-local resolver. If the host gets its resolver through DHCP
or another runtime service, verify `/etc/resolv.conf` after switching instead
of inferring the address from the Nix configuration.

##### Initial Setup

Apply the system configuration before you start an attached VM. The module
starts Agent Vault on `127.0.0.1:14321`, its proxy on `127.0.0.1:14322`, and
the per-user HAProxy bridge through a lingering systemd user manager.

The installation uses two independent passwords:

- The master password for the server encrypts Agent Vault state. NixOS
  generates 48 random bytes with `openssl rand -base64 48` and stores the
  result at `/var/lib/voom-agent-vault-secrets/master-password`, readable only
  by root. Do not use this value to log in to the web interface.
- The password for the owner account authenticates the administrator. Choose
  this password during the first registration and store it in the normal
  operator password manager.

After you apply the system configuration, verify the services before you
register an owner:

``` bash
sudo systemctl status agent-vault.service voom-agent-vault-firewall.service \
  voom-agent-vault-resolver-check.service \
  voom-agent-vault-firewall-check.timer
systemctl --user status voom-agent-vault-bridge.service
curl --fail http://127.0.0.1:14321/health
```

The first registered account becomes the owner of the Agent Vault instance.
Register this account once through the CLI or the web interface. The CLI
prompts for the owner account password:

``` bash
agent-vault auth register --address http://127.0.0.1:14321 --email <email>
```

The web interface is available only on the host at
<http://127.0.0.1:14321>. To administer the host from another machine, create an
SSH tunnel and open that same local URL in a browser:

``` bash
ssh -N -L 14321:127.0.0.1:14321 <host>
```

Registration through the web interface does not authenticate the Agent Vault
CLI on the host. Before you run `voom-agent-vault sync`, create the operator
session as the user that owns the Voom state:

``` bash
agent-vault auth login --address http://127.0.0.1:14321
```

Registration through the CLI already creates this session.

After registration, create every vault named by an assignment:

``` bash
agent-vault vault create development
agent-vault vault create personal
```

Use Agent Vault commands or its local web interface to configure each vault's
services and credentials. Keep the operator session on the host. Do not copy it
into a guest.

For GitHub API and Git-over-HTTPS access, add these credentials:

| Credential        | Value                         |
|-------------------|-------------------------------|
| `GITHUB_TOKEN`    | The personal access token     |
| `GITHUB_USERNAME` | The GitHub account user name  |

Create both entries in the vault's Credentials section before you configure
the services. The Basic-auth service selects `GITHUB_USERNAME` as a credential.
The field does not accept the user name as a literal value.

Add a service for GitHub API requests:

| Setting          | Value             |
|------------------|-------------------|
| Name             | `github`          |
| Host             | `api.github.com`  |
| Authentication   | Bearer            |
| Token credential | `GITHUB_TOKEN`    |

Add a second service for Git smart HTTP:

| Setting              | Value               |
|----------------------|---------------------|
| Name                 | `github-git`        |
| Host                 | `github.com`        |
| Authentication       | Basic               |
| Username credential  | `GITHUB_USERNAME`   |
| Password credential  | `GITHUB_TOKEN`      |

Both services are required. The `api.github.com` service authenticates GitHub
API and `gh` requests. The `github.com` service authenticates Git clone, fetch,
and push operations over HTTPS. One service does not cover the other host.

Do not add a substitution or a wildcard host. `voom-egress-run` gives `gh` the
nonsecret placeholder `GH_TOKEN=__github_token__` because `gh` requires the
variable. The API service replaces its Bearer header with the stored token. The
Git service replaces Git's Basic header with the user name and stored token.

After you create the vaults, verify their names against the assignments in the
same host-specific module. Stop all newly assigned VMs. Then reconcile the
declarations and tokens as the user that owns the Voom state:

``` bash
voom-agent-vault sync
voom-agent-vault status
```

`sync` processes every assignment and existing attachment and reports partial
failures. A first attachment and an egress declaration replacement require a
stopped VM. Token rotation, profile changes, disable, and enable can run while
the VM is running. `sync` reports an assignment for a missing VM as pending and
continues with the other assignments.

The default persistent state is
`~/.local/state/voom-agent-vault`. Runtime sockets and generated HAProxy files
are under `/run/user/$UID/voom-agent-vault`. Both paths come from the NixOS
module so the CLI, user service, and backup exclusions cannot select different
locations. Every process running as the Voom owner can read all VM agent tokens
and connect to all VM sockets. Other unprivileged local users cannot access
them.

##### Attach a New VM

Complete the one-time [Initial Setup](#initial-setup) first. Then use this
procedure for each new VM:

1. Create the VM, but do not start it:

   ``` bash
   voom create my-vm --image golden
   ```

2. In the private repository for the host, map the exact VM name to a vault
   that exists in Agent Vault:

   ``` nix
   services.voomAgentVault.assignments."my-vm" = "development";
   ```

3. Apply the host configuration. Keep the VM stopped:

   ``` bash
   nix run .#build-switch
   ```

4. As the user that owns the Voom state, authenticate the Agent Vault CLI if
   necessary and reconcile the attachment:

   ``` bash
   agent-vault auth login --address http://127.0.0.1:14321
   voom-agent-vault sync
   voom-agent-vault status my-vm
   ```

   `status` must report a healthy, enabled attachment. The manager records the
   VM's immutable ID, creates its Agent Vault agent and token, renders its
   private bridge socket, and creates the Voom egress declaration.

5. Start and bootstrap the VM:

   ``` bash
   voom start my-vm
   voom ssh my-vm -- home-bootstrap
   ```

6. Run the checks under
   [Validate an Attachment](#validate-an-attachment) and confirm that the
   requests appear in the Agent Vault request log. A new VM must not receive a
   copied GitHub token or forwarded SSH agent. If the image already contains a
   credential, remove it only after the brokered access checks pass.

All attachments use the same host network boundary. Complete
[Validate the Host Network Boundary](#validate-the-host-network-boundary) for
the initial host rollout and repeat it after firewall, Tailscale, or Agent
Vault network-policy changes. You do not need this validation for each new VM.

If an assignment exists before its VM, `sync` reports it as pending. Create the
stopped VM and rerun `sync`. If the bridge is unavailable, an enabled
attachment prevents the VM from starting. Use the recovery procedure under
[Routine Operations](#routine-operations).

##### Guest Commands

The guest image includes `voom-egress-run`. Use it directly for a command that
does not have a guest wrapper:

``` bash
voom-egress-run -- curl --fail https://api.github.com/user
```

The helper refuses to start if Voom did not publish an explicit egress
manifest. The helper sets proxy and CA variables for common HTTP clients.
Clients with a built-in root store can ignore these variables and require
separate testing. GitHub CLI also requires a nonempty local `GH_TOKEN`. The
helper supplies a nonsecret placeholder when the variable is absent. Node's
environment proxy support requires Node 22.21 or later.

The Fish configuration in the guest applies `voom-egress-run` automatically
to `git` and `gh` when the manifest exists. Codex and Claude use executable
wrappers so Herdr and other non-Fish callers receive the same egress
environment. The wrappers also run Codex with `--yolo` and Claude Code with
`--dangerously-skip-permissions`. The VM is the isolation boundary for these
agents. Host installations keep the agents' normal permission controls.

Run these commands normally:

``` bash
gh api user --jq .login
git fetch
codex
claude
```

From a normal Fish shell in the guest, use `command git` or `command gh` to
bypass the functions. Use this form to inspect or remove a credential stored
inside the guest. A non-Fish command must use `voom-egress-run -- git ...` or
`voom-egress-run -- gh ...` for brokered GitHub access unless it inherited the
environment from an agent wrapper.

HAProxy allows 10 seconds to establish an upstream connection. It applies a
15-minute idle timeout to clients, servers, CONNECT tunnels, WebSockets, and
streaming requests. A client must create a new request or connection after an
idle connection closes.

##### Validate an Attachment

Run these commands after you attach a VM:

``` bash
gh api user --jq .login
voom-egress-run -- curl --fail https://api.github.com/user
git ls-remote https://github.com/<owner>/<private-repository>.git HEAD
git -C <repository> fetch
git -C <repository> push --dry-run origin HEAD
```

All commands must succeed. Use a low-risk repository for the Git tests. Confirm
that the requests appear under the `github` and `github-git` services in
the Agent Vault request log. If the VM uses Git LFS or GitHub release uploads,
test those operations as well. When migrating an existing VM, do not remove its
guest credential until these checks pass.

##### Migrating an Existing VM

New VMs must not receive a GitHub credential. For an existing VM, first
[validate its attachment](#validate-an-attachment). Then identify how the guest
supplies its old credential without printing the credential value:

``` bash
command gh auth status --hostname github.com
env | sed 's/=.*//' | grep -E '^(GH_TOKEN|GITHUB_TOKEN)$'
git config --show-origin --get-regexp '^credential\.' || true
```

If GitHub CLI stores the credential, remove it with:

``` bash
command gh auth logout --hostname github.com
```

Remove tokens supplied by shell configuration, environment files, Git
credential stores, or other guest secret mechanisms. Then start a new shell.

Verify that direct authenticated access fails:

``` bash
command gh api user --jq .login                   # must fail
curl --fail https://api.github.com/user           # must fail with HTTP 401
env GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<private-repository>.git HEAD # must fail
```

Repeat [Validate an Attachment](#validate-an-attachment) without `command` or
`env`; all brokered requests must still succeed and appear under the `github`
and `github-git` services in the Agent Vault request log.

##### Routine Operations

``` bash
voom-agent-vault status [vm]
voom-agent-vault sync
voom-agent-vault rotate <vm>
voom-agent-vault disable <vm> --reason '<reason>'
voom-agent-vault enable <vm>
voom-agent-vault detach <vm>
```

Voom calls and Agent Vault API requests have a default 60-second timeout. This
exceeds Voom's 20-second fail-closed runtime shutdown window. The manager kills
and reaps a timed-out Voom subprocess before it reads Voom state again.

`disable` is the emergency command. The command does not take the management
lock and does not need a session for an Agent Vault administrator. `disable`
writes a durable hold, then disables Voom egress and closes live tunnels.
`sync` cannot clear the hold. Only `enable` removes the hold after it validates
the token, vault, CA, bridge configuration, and socket.

If HAProxy is unavailable, an enabled attachment prevents a stopped VM from
starting because Voom cannot probe its backend socket. Use the emergency
disable command, start the VM, repair the bridge, and then enable the
attachment.

Inspect service failures with:

``` bash
systemctl status agent-vault.service voom-agent-vault-firewall.service
systemctl status voom-agent-vault-firewall-check.service \
  voom-agent-vault-resolver-check.service \
  voom-agent-vault-firewall-check.timer
systemctl --user status voom-agent-vault-bridge.service
journalctl -u agent-vault.service \
  -u voom-agent-vault-firewall.service \
  -u voom-agent-vault-firewall-check.service \
  -u voom-agent-vault-resolver-check.service -b
journalctl --user -u voom-agent-vault-bridge.service -b
```

The firewall verifier requires the owner-match jump for Agent Vault to be rule
1 of both filter `OUTPUT` chains. The verifier stops Agent Vault if either IPv4
or IPv6 protection is missing. The same periodic check rejects an unconfigured
host-local resolver. Its timer does not depend on or restart the guard. A
stopped or broken guard produces a failed status check and leaves Agent Vault
stopped.

After a NixOS firewall or Tailscale change, verify that the service and
`voom-agent-vault status` remain healthy. Repeat the
[host network boundary checks](#validate-the-host-network-boundary), including
the Caddy and Tailscale checks.

Agent Vault retains request logs for seven days, up to 10,000 rows per vault.
Retention and rate-limit locking are enabled in the system service.

##### Backup and Recovery

The host backup excludes agent tokens, the operator session, and generated
HAProxy maps. Before each host restic backup, NixOS creates a consistent SQLite
snapshot and copies Agent Vault's encrypted CA state into
`/var/cache/agent-vault-backup`. This directory is mode `0700`, and snapshot
files are mode `0600`, owned by `agent-vault`. A snapshot failure does not
suppress the rest of the host backup. Restic can use the last successful
snapshot.

NixOS generates the master password at
`/var/lib/voom-agent-vault-secrets/master-password`. Store an encrypted copy
separately from the restic repository. For example, read it as root directly
into the chosen encryption or password-manager command. Do not copy it through
the clipboard, shell arguments, or a world-readable temporary file. The
database and encrypted CA key are not usable without this value.

After restoring the database, CA files, and master password, leave attached
VMs stopped or disabled. Agent token files are intentionally absent. Log in as
the operator and run `voom-agent-vault sync`. The command rotates missing
tokens, rebuilds the bridge, validates each attachment, and enables only
attachments without an emergency hold.

The module pins Agent Vault to version 0.39.3. The manager refuses
administrative changes if the installed CLI version or required management
APIs differ. The package installs Agent Vault's MIT license and upstream README
in its Nix output.

##### Deployment Validation

The configuration is safe to deploy with an empty assignment map. Complete
this checklist before you rely on the broker. Repeat the relevant checks after
changes to Voom egress, Agent Vault, the firewall, Tailscale, Caddy, or backup
and recovery.

###### Validate the Host Network Boundary

On the host, confirm that the Agent Vault jump is the first rule in both
`OUTPUT` chains:

``` bash
agent_vault_uid=$(id -u agent-vault)
test "$(sudo iptables -t filter -S OUTPUT | grep '^-A OUTPUT' | head -n 1)" = \
  "-A OUTPUT -m owner --uid-owner $agent_vault_uid -j VOOM_AGENT_VAULT"
test "$(sudo ip6tables -t filter -S OUTPUT | grep '^-A OUTPUT' | head -n 1)" = \
  "-A OUTPUT -m owner --uid-owner $agent_vault_uid -j VOOM_AGENT_VAULT"
```

Both `test` commands must succeed. Restart Tailscale and repeat these checks.
Confirm that Caddy remains reachable through the tailnet and unreachable
through the host's non-tailnet addresses.

From an attached test guest, force requests through the proxy instead of the
wrapper's loopback bypass:

``` bash
curl --noproxy '' --proxy http://192.168.127.1:3128 \
  --connect-timeout 5 http://127.0.0.1:14321/health
curl --noproxy '' --proxy http://192.168.127.1:3128 \
  --connect-timeout 5 --insecure https://127.0.0.1:14321/
```

Both requests must fail closed. Repeat both forms for every current host LAN,
Tailscale, link-local, and global IPv6 address, `localhost`,
`169.254.169.254`, `100.100.100.100`, one IPv4 and IPv6 tailnet peer, and a
test hostname that resolves to a blocked address.

Agent Vault can report a blocked or otherwise unreachable upstream as HTTP
`502`. With `curl --fail`, this response produces exit status 22. This result
is fail-closed when the destination is reachable from an authorized source,
brokered GitHub requests succeed, and `voom-agent-vault status` remains
healthy. A refusal from an unused target port does not prove that Agent Vault
blocked the destination.

Complete these remaining checks:

1. Verify both firewall jumps, the periodic firewall verifier, the resolver
   check, Agent Vault, and the user bridge.
2. Restart the NixOS firewall, the Agent Vault firewall guard, Tailscale, Agent
   Vault, and the bridge separately. Confirm fail-closed ordering and healthy
   recovery.
3. Complete the blocked-destination matrix above for plain HTTP and CONNECT.
4. Confirm Caddy's tailnet-only exposure after the firewall and Tailscale
   restarts.
5. Attach a disposable VM, exercise disable, enable, rotation, profile change,
   detach, bridge failure, and host reboot, and confirm `status` after each
   step. During rotation, confirm that Agent Vault 0.39.3 returns HTTP `401`
   from `/discover` for the invalidated token and HTTP `200` for the replacement
   token.
6. Restore the Agent Vault database, encrypted CA state, and master password in
   an isolated test before relying on the backup.

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

Then enable declarative Caddy publishing in your system configuration
repository's `host-info.nix`:

``` nix
{
  nixosTailnetCaddy = {
    enable = true;

    # Defaults to /etc/caddy/cloudflare.env; set this if you keep the token
    # elsewhere (e.g. a secrets manager's /run/secrets path).
    # cloudflareEnvironmentFile = "/run/secrets/caddy-cloudflare.env";

    # The default is [ ":443" ]. The Tailscale module in the shared repository
    # trusts tailscale0, and this module does not open TCP/443 on non-tailnet
    # interfaces. Set this to an explicit Tailscale address if socket-level
    # binding is preferred.
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

This is implemented with two systemd units:

- `voom-caddy-sync.service` is a oneshot unit bound to Caddy. The dynamic route
  list lives only in Caddy's running config, so anything that (re)loads the
  declarative config, such as a reboot, `systemctl restart caddy`, or a
  `nixos-rebuild` that changes Caddy's config, empties the state; the oneshot
  re-runs the sync on every such event, so routes self-heal across restarts.
- `voom-caddy-sync-watch.service` follows `voom events` and re-syncs when a VM
  starts or stops and when an automatic forward is installed or removed.

Voom events are wake-up hints rather than a state replica, so every event
triggers a full re-sync, with bursts (e.g. a booting VM installing one forward
per port) coalesced into a single sync.

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
(also check both units), and inspect the synced routes:

``` bash
systemctl status voom-caddy-sync.service
journalctl -u voom-caddy-sync-watch.service -f
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

Next, add a route with `syncer = "docker"` to your system configuration
repository's `host-info.nix`:

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
  on container start and stop, exactly as the Voom watcher follows `voom
  events`.

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

The Emacs flake is automatically built and
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
part of the shared repository (and not managed by _home-manager_). It is cloned
into `~/.emacs.d` automatically by the
[`home-bootstrap`](./scripts/home-bootstrap) script, or can alternatively be
cloned directly:

``` bash
git clone https://github.com/mjrusso/.emacs.d ~/.emacs.d
```

## Usage

Run these commands from your system configuration repository.

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
architecture. In a VM guest created by the system configuration, it selects
the matching `vm-<system>-<format>` configuration instead. On x86_64 NixOS,
the direct equivalents are:

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
> files do not need to be committed to the system configuration repository.)

### Updating dependencies

Both repositories are flakes, and each repository has its own `flake.lock`.
The lock file in the shared repository pins inputs such as Nixpkgs, Home
Manager, and nix-darwin. To update those inputs, run this command in the shared
repository:

``` bash
nix flake update
```

Commit and push the updated lock file with the related changes. Your system
configuration repository continues to use its pinned revision of the shared
repository until you update it. Run this command in the system
configuration repository to update only that revision:

``` bash
nix flake update nixos-config
```

The lock file in the system configuration repository records the selected
revision of the shared repository and the resulting dependency graph. Its
inputs that follow the shared repository, such as Nixpkgs, update at the same
time. Use `nix flake update` without an input name if you add other independent
inputs and want to update all of them.

The `--override-input nixos-config path:../nixos-config` option temporarily uses
a local checkout. It does not change either lock file.

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
nix build .#checks.x86_64-linux.darwin-aarch64-darwin@desktop
nix build .#checks.x86_64-linux.nixos-x86_64-linux
nix build .#checks.x86_64-linux.image-x86_64-linux-docker
```

Each check forces full evaluation of a configuration's module system without
building the target derivation. Use the `checks.<host-system>` namespace for
the machine running the check; evaluating a Darwin configuration this way does
not require a Darwin builder.

## References

- https://github.com/dustinlyons/nixos-config
- https://github.com/mitchellh/nixos-config
- https://determinate.systems/posts/nix-direnv/
- https://mitchellh.com/writing/nix-with-dockerfiles
