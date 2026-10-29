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

#### MacOS Voom Hosts

To back up MacOS Voom guests, enable `services.voomBackup` in the host's
desktop or laptop nix-darwin configuration:

``` nix
services.voomBackup = {
  enable = true;
  volume = "/Volumes/Backups";
  repository = "/Volumes/Backups/restic/voom";
};
```

This installs `voom-backup`, `restic-voom`, and the primary user's
`org.nixos.voom-backup` LaunchAgent. The job runs when the agent is loaded,
including at login, and daily at 03:00 while the user is logged in. If the
Mac is asleep at 03:00, the job runs when it wakes. It backs up running
MacOS guests and skips Linux guests.
For Linux hosts, see [Linux Voom Hosts](#linux-voom-hosts).

Each run copies the guest's `/Users` directory over SSH to
`~/Library/Caches/voom-backup/<guest>/Users`, then backs up those files with
Restic. Snapshots use the guest's name as the Restic host and have the
`voom` tag. Only the primary user can access the staging directory.

The guest's own virtual disk and Apple platform state are stored on the
Voom host and are not captured. VM files under the guest's `/Users`
directory are copied unless another exclusion applies. For databases,
use their backup tools or stop them before copying files.

After copying the guests, the job applies a Restic retention policy of
seven daily, four weekly, and six monthly snapshots. The policy considers
only snapshots tagged `voom`, grouped by guest name and staging path.

After a successful guest listing, the job deletes its staging copies for
guests that no longer exist. It keeps staging for stopped guests. Failed
or invalid listings preserve existing staging copies. Deleting staging
does not delete Restic snapshots.

The staging directory and repository must not overlap, including through
symlinks.

Before the first run:

1. Install an SSH private key without a passphrase at
   `~/.ssh/id_ed25519_voom_read` on the Mac host. Its public key must match
   `userInfo.voomReadKey`. Set `voomReadKeySource` to gvproxy's gateway,
   normally `192.168.127.1`. The guest restricts this key to
   `sudo rrsync -ro /Users`. Backup SSH connections ignore the interactive
   SSH configuration and use only the backup key.
2. Create the repository password file, readable only by the primary user:

   ``` bash
   sudo install -d -m 0755 /etc/restic
   sudo sh -c 'umask 077; set -C; openssl rand -base64 32 > /etc/restic/voom-password'
   sudo chown "$USER" /etc/restic/voom-password
   sudo chmod 0400 /etc/restic/voom-password
   ```

   Keep a copy of the password in your password manager. Do not overwrite
   this file after the repository is created.
3. Mount the backup volume and create the repository's parent directory as
   the primary user. For the example above:

   ``` bash
   mkdir -p /Volumes/Backups/restic
   ```

   Restic creates the repository on the first run. The job stops if the
   volume is not mounted.
4. From your system configuration repository on the Mac host, update the
   running guests to authorize the backup key, then rebuild the host to
   start the backup job. Update stopped guests before backing them up:

   ``` bash
   nix run .#voom-update -- --darwin
   nix run .#build-switch
   ```

5. Run a backup, restore it, and check the files:

   ``` bash
   voom-backup
   restic-voom snapshots --host <guest>
   restic-voom restore latest --host <guest> --target /tmp/voom-restore
   ```

##### MacOS Backup Operations

Scheduled runs append timestamps, guest names, errors, and Restic output to
`~/Library/Logs/voom-backup.log`. Read recent entries or follow the log:

``` bash
tail -n 100 ~/Library/Logs/voom-backup.log
tail -f ~/Library/Logs/voom-backup.log
```

Check the job's last exit status or start another run with the same log:

``` bash
launchctl print "gui/$(id -u)/org.nixos.voom-backup"
launchctl kickstart "gui/$(id -u)/org.nixos.voom-backup"
```

Running `voom-backup` directly prints to your terminal. Copy and snapshot
errors cause a nonzero exit status after the job processes the other
guests. A failed copy skips that guest's snapshot. MacOS can deny SSH
access to files even with sudo; check the log for permission errors.

Copies stop after five minutes without rsync I/O. SSH uses a 15-second
connection timeout and disconnects after three unanswered keepalives sent
15 seconds apart. A timed-out copy fails that guest's backup; the job
continues with the next guest and releases its lock when it finishes.

If a killed job leaves `~/Library/Caches/voom-backup/.lock`, check that no
backup is running, then remove that empty directory.

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
tunnel <user>@<host> 8385:8384
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

Physical NixOS hosts can back up the user's home directory over SFTP using
[restic](https://restic.net/). Enable `services.hostBackup` in the host's
NixOS configuration through the constructor's `extraModules`. The shared
[host backup module](./modules/nixos/host-backup.nix) defines the job.
Container and VM images do not enable backups.

``` nix
extraModules = [
  {
    services.hostBackup = {
      enable = true;
      target = "<target>";
      repositoryPath = "<repository-path-on-target>";
    };
  }
];
```

`target` is an SSH host reachable from this machine; add it to
`nixosExtraHosts` if it has no DNS entry. `repositoryPath` is the full
repository path on the target, such as `/backups/restic/<hostname>`. Include
a per-host directory when sharing a target drive; the module uses this
path as written.

Additional `services.hostBackup` options:

| Key                    | Default                                                     |
|------------------------|-------------------------------------------------------------|
| `targetUser`           | `user` from your system configuration repository's `user-info.nix` |
| `passwordFile`         | `/etc/restic/password`                                      |
| `identityFile`         | that user's `~/.ssh/id_ed25519_restic`                      |

Setting `services.hostBackup.enable = false`, or omitting the configuration,
removes the service and its timer. Disable `services.voomBackup` too if it
uses this host backup.

##### Initial Setup

1. Generate a dedicated key for the backup and authorize it on the target. The
   timer does not have an agent or a terminal, so this key must **not** have a
   passphrase:

   ``` bash
   ssh-keygen -t ed25519 -N "" -C "restic (unattended)" \
     -f ~/.ssh/id_ed25519_restic
   ```

   For a Mac target using this configuration, add the public key to
   `resticKey` in your system configuration repository's `user-info.nix`,
   then rebuild the target. The Mac confines the key to SFTP, and
   `resticKeySource` defines the addresses it can connect from:

   ``` nix
   resticKey = "ssh-ed25519 AAAA...";
   resticKeySource = "<source>";
   ```

   For other targets, authorize the key on the SFTP server and grant write
   access to the repository directory.

   Verify access from the source to the target:

   ``` bash
   echo quit | env -u SSH_AUTH_SOCK sftp -q -o BatchMode=yes \
     -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_restic <user>@<target>
   ```

2. Create the parent directory on the target. restic creates the repository
   directory itself, but not missing parents:

   ``` bash
   ssh <user>@<target> 'mkdir -p <repository-parent-directory>'
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
restic-<hostname> snapshots --host <hostname>
restic-<hostname> stats latest --host <hostname>
restic-<hostname> check
```

Use `--host <hostname>` to select this host's snapshots; the repository may
also contain guest snapshots. To restore into a scratch directory or back
over the original paths:

``` bash
restic-<hostname> restore latest --host <hostname> --target /tmp/restore
restic-<hostname> restore latest --host <hostname> --target / --include <path>
```

<a id="voom-guests"></a>

#### Linux Voom Hosts

For guests running on a Mac host, see [MacOS Voom Hosts](#macos-voom-hosts).

To back up Linux [Voom](https://github.com/mjrusso/voom) guests, complete the
[host backup setup](#backups), then enable `services.voomBackup` in the
host's NixOS configuration through the constructor's `extraModules`:

``` nix
extraModules = [
  {
    services.voomBackup.enable = true;
  }
];
```

This adds `voom-backup.service` and a daily timer with up to one hour of
random delay. The timer catches up after downtime. The job copies running
guests' `/home` and `/var/lib/docker/volumes` to
`/var/cache/voom-staging/<guest>`, then backs up those files into the host's
Restic repository using its `restic-<hostname>` wrapper and repository
credentials. Stopped guests are skipped. Snapshots use the guest's name as
the Restic host and have the `voom` tag. The guest SSH key defaults to
`~/.ssh/id_ed25519_voom_read`; set `services.voomBackup.identityFile` to use
a different key.

The guest's virtual disk and Voom configuration live on the host and are
not captured by this job. VM files under the guest's `/home` are copied
unless another exclusion applies. For databases, use their backup tools
or stop them before copying files.

Staging is kept between runs. After a successful guest listing, the job
deletes staging for guests that no longer exist. It keeps staging for
stopped guests. Failed or invalid listings preserve existing staging
copies. Deleting staging does not delete Restic snapshots. The host's
daily Restic job applies a retention policy of seven daily, four weekly,
and six monthly snapshots, grouped by host name and source paths.

Before the first run:

1. Generate the key. As with the repository key, it must have no passphrase:

   ``` bash
   ssh-keygen -t ed25519 -N "" -C "voom read" \
     -f ~/.ssh/id_ed25519_voom_read
   ```

2. Add the public key to `voomReadKey` in your system configuration
   repository's `user-info.nix`. Set `voomReadKeySource` to gvproxy's
   gateway, normally `192.168.127.1`. The guest restricts this key to
   `sudo rrsync -ro /`. This key is separate from the repository key.

3. Update the running guests to authorize the backup key, then rebuild this
   host, in this order. Update stopped guests before backing them up.

   ``` bash
   nix run .#voom-update -- --nixos
   nix run .#build-switch
   ```

4. Run a backup, restore it, and check the files. Run the Restic commands as
   the backup user:

   ``` bash
   sudo systemctl start voom-backup.service
   restic-<hostname> snapshots --host <guest> --tag voom
   restic-<hostname> restore latest --host <guest> --tag voom --target /tmp/voom-restore
   ```

##### Linux Backup Operations

Start a backup, check its status, or read recent logs:

``` bash
sudo systemctl start voom-backup.service
systemctl status voom-backup.service
systemctl list-timers voom-backup.timer
journalctl -u voom-backup.service -n 100
```

Follow the guest backup log:

``` bash
journalctl -fu voom-backup.service
```

Run these commands on the Voom host. Logs include guest names, copy errors,
and Restic output. Copy or snapshot errors cause a nonzero exit status
after the job processes the other guests. A failed `/home` copy skips that
guest's snapshot. If only the Docker volume copy fails, the job still
attempts a snapshot of the staged files and reports a failure. That
snapshot can contain partial or older Docker volume data. Files removed
during a copy (rsync exit 24) do not fail the job. An incomplete Restic
snapshot (exit 3) fails the job.

Backup SSH connections ignore the interactive SSH configuration and use
only the backup key. Copies stop after five minutes without rsync I/O.
SSH uses a 15-second connection timeout and disconnects after three
unanswered keepalives sent 15 seconds apart. A timeout fails that guest's
copy and the job continues with the other guests.

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

#### PCI Passthrough

The VFIO module binds PCI devices, typically a GPU, to the `vfio-pci` driver at
boot so that VMs can use them. The host cannot use a device bound to
`vfio-pci`.

1. Enable the IOMMU (AMD-Vi or VT-d) in the firmware.

2. Check that every function of the device is in an IOMMU group, and that the
   group contains nothing else:

   ``` bash
   nix shell nixpkgs#pciutils -c lspci -nnk -d 10de:
   ls /sys/bus/pci/devices/0000:41:00.0/iommu_group/devices
   ```

   Replace `10de:` with the device's vendor ID and `0000:41:00.0` with its
   address.

3. Enable the module in your system configuration repository's
   `host-info.nix`:

   ``` nix
   {
     nixosVfio = {
       # The vendor:device ID of every function of the device, from `lspci -nn`.
       pciIds = [ "10de:1e84" "10de:10f8" "10de:1ad8" "10de:1ad9" ];

       # The "Kernel driver in use" that `lspci -nnk` reports for each
       # function. The module loads vfio-pci before these drivers, so that
       # vfio-pci claims the device first.
       hostDrivers = [ "nouveau" "snd_hda_intel" "xhci_pci" "i2c_nvidia_gpu" ];
     };
   }
   ```

   The module also gives the `kvm` group access to `/dev/vfio`, and removes
   the user's memlock limit, because VFIO locks all of a VM's memory.

4. Apply the configuration and reboot. The module passes the device IDs to
   `vfio-pci` on the kernel command line, which takes effect only at boot.

5. Check that `lspci -nnk` reports `vfio-pci` as the driver for every
   function, and that `ulimit -l` in a new SSH session reports `unlimited`.

If the device is the host's only GPU:

- The display stops updating when `vfio-pci` loads in the initrd, which happens
  before the ZFS passphrase prompt. Unlock over SSH instead, as described in
  [SSH-in-initrd unlock](#ssh-in-initrd-unlock).
- The boot menu still appears, so you can select a previous generation at the
  console if a change breaks booting.
- Set `nixosDesktop = false` in `host-info.nix`. Otherwise the local
  desktop fails to start.

To assign the GPU to a VM, see [NVIDIA GPU in a VM](#nvidia-gpu-in-a-vm).

#### Hyprland desktop

The [desktop module](./modules/nixos/desktop.nix) provides local and headless
Hyprland sessions. Both use the [Hyprland config](./modules/nixos/config/hyprland.nix)
and PipeWire audio. Noctalia provides the top bar, application launcher,
notifications, clipboard history, screenshots, and desktop controls.
Enable one session at a time; Sunshine can stream either.
Set the options below in the configuration's `extraModules`.

##### Local session

Physical NixOS hosts enable `services.localDesktop.enable` by default, using
`hostInfo.nixosDesktop` when that field is set. VM and container images leave
it disabled. Local sessions initially use connected monitors at their preferred
resolution and do not require NVIDIA graphics. Saved display settings take
precedence.

Log in at the greetd text prompt with the configured user's password. If the
user only has SSH keys, set a password first with `sudo passwd <user>` over
SSH. By default, Noctalia locks the session after ten minutes of inactivity and
before suspend.

Set `services.localDesktop.enable = false` to disable the local session.

##### Headless session

`services.headlessDesktop.enable` defaults to `false`. It starts Hyprland
without a monitor or dummy plug, with a persistent `HEADLESS-STREAM` output.
greetd logs in automatically as `userInfo.user`.

The headless session requires NVIDIA graphics configured separately. For VM
guests, enable the driver and desktop in both the VM configuration and its
qcow/raw image outputs:

``` nix
{
  hardware.nvidiaGuest.enable = true;
  services.headlessDesktop.enable = true;
}
```

The guest driver uses NVIDIA's open kernel modules, which require Turing
(RTX 20 series) or newer hardware.

Physical hosts must set `services.localDesktop.enable = false` and configure
the NVIDIA driver, including `services.xserver.videoDrivers = [ "nvidia" ]`
and a choice of `hardware.nvidia.open` appropriate for the GPU.

For streaming, also [enable Sunshine](#stream-with-sunshine) before applying
the configuration. Apply the configuration and reboot. For VMs, assign the GPU
before booting and use the [VM update commands](#running-vm-images). For Voom,
run `voom restart <vm>` on the host to restart the guest and its host helpers,
including gvproxy. Rebooting from inside the guest does not restart gvproxy.

Without NVIDIA hardware, the headless desktop stays stopped and SSH remains
available. Software rendering and virtual GPUs are unsupported for headless
sessions.

After restarting, SSH into the headless machine as the desktop user and check:

``` bash
nvidia-smi
systemctl status greetd
systemctl --user status headless-display
hyprctl --instance 0 monitors
```

`nvidia-smi` should list the assigned GPU. Expect greetd to be running and
headless-display to be `active (exited)`, meaning display creation completed.
The monitor list should include `HEADLESS-STREAM`.

##### Stream with Sunshine

To stream either session, set this alongside the desktop options before
applying the configuration and rebooting:

``` nix
{
  services.sunshine.enable = true;
}
```

Sunshine defaults to disabled. It starts with the graphical session, so log in
locally before connecting to a local desktop. For headless sessions, it waits
for the virtual output and captures that output and the virtual audio sink.
Local sessions use Sunshine's default display and audio sink. NVIDIA sessions
use NVENC; other local sessions use Sunshine's automatic encoder selection.

SSH into the streaming machine as the desktop user and confirm Sunshine is
running:

``` bash
systemctl --user status sunshine
```

Use Moonlight on the client. For a physical host, connect to its LAN or
Tailscale address. For a Voom guest, forward these ports through the host,
using the same port numbers on both sides:

| Protocol | Ports                             |
|----------|-----------------------------------|
| TCP      | 47984, 47989, 48010               |
| UDP      | 47998, 47999, 48000, 48002, 48010 |

On the Voom host, add the forwards in Fish, replacing `your-vm` with the VM
name:

``` fish
set vm_name your-vm

for port in 47984 47989 48010
    voom forward add $vm_name $port --protocol tcp --lan
end

for port in 47998 47999 48000 48002 48010
    voom forward add $vm_name $port --protocol udp --lan
end

voom forward list $vm_name
```

`--lan` binds to `0.0.0.0`, including the host's LAN and Tailscale addresses.
To listen only on Tailscale, replace `--lan` with
`--bind (tailscale ip -4)`. Voom's default binding, `127.0.0.1`, is reachable
only from the host and cannot accept a direct Moonlight connection from
another machine. Forwards survive VM restarts.

The host firewall must allow the streaming ports on the interface used by the
client. This repo's NixOS host configuration trusts `tailscale0`, so Tailscale
connections need no additional firewall rules. Enabling Sunshine opens its
ports in the guest firewall; the guest does not need Tailscale.

Use `tunnel` on the client to reach the administration UI:

``` fish
tunnel <ssh-host> 47990
```

The SSH connection must reach the machine running Sunshine. For a guest whose
SSH port is forwarded as `<guest-ssh-port>` on the Voom host, use:

``` fish
tunnel <guest-user>@<voom-host> 47990 -- -p <guest-ssh-port>
```

Open `https://localhost:47990`, accept the self-signed certificate, and create
administrator credentials. Add the physical host's address or the Voom host's
Tailscale address in Moonlight. Enter Moonlight's pairing PIN in Sunshine, then
select **Desktop**. For the default headless display, set Moonlight to 4K/60 Hz
with H.264 or HEVC.

Edit `services.sunshine.settings` and `services.sunshine.applications.apps`
in the [desktop module](./modules/nixos/desktop.nix) to change settings or
applications. These files are managed by Nix and cannot be edited through
Sunshine's web UI. Credentials and paired clients are stored in the desktop
user's `~/.config/sunshine`.

##### Desktop settings

Open Noctalia settings with Super+comma to customize the bar, appearance,
notifications, and idle behavior. Super+S opens the control center for audio
controls and the wallpaper picker.

Click the monitor icon in the bar to open **Displays Settings** (nwg-displays).
Click **Apply**, then **Keep**, to save changes to
`~/.config/hypr/monitors.lua`. Rebuilds preserve this file.

The headless display defaults to 3840×2160 at 60 Hz with 150% scaling.
nwg-displays changes the guest desktop's resolution and scaling. Moonlight
keeps its configured video resolution and scales the desktop to fit.

The GNOME wallpapers are managed by Nix in `~/Pictures/Wallpapers/GNOME`. Add
your own images alongside that folder in `~/Pictures/Wallpapers`, then choose a
background in the picker. Noctalia also supports favorites and automatic
rotation.

Home Manager activation clears GUI overrides for settings declared in
[noctalia.nix](./modules/nixos/config/noctalia.nix), including the bar's start
widgets and session locking. GUI changes to these settings last until the next
activation. Other preferences, including wallpaper and theme choices, persist
in `~/.local/state/noctalia/settings.toml`. Hyprland keybindings and window
behavior live in [hyprland.nix](./modules/nixos/config/hyprland.nix). Headless
sessions disable session locking and idle locking by default.

Applying a changed Hyprland configuration reloads it automatically without
closing windows. To reload it manually:

``` bash
hyprctl --instance 0 reload
```

##### Keybindings

When streaming, enable Moonlight's capture of system keyboard shortcuts so
Alt+Tab and Super shortcuts reach the guest. Files (Nautilus) is the default
file manager; Ctrl+L lets you enter a path. Workspaces 1–9 remain visible in
the bar even when empty.

| Binding                             | Action                                  |
|-------------------------------------|-----------------------------------------|
| Super+Space                         | Open the application launcher           |
| Alt+Tab                             | Switch windows through Noctalia         |
| Super+S                             | Open the control center                 |
| Super+comma                         | Open Noctalia settings                  |
| Super+Ctrl+V                        | Open clipboard history                  |
| Print                               | Capture a screen region                 |
| Super+L (local sessions)            | Lock the session                        |
| Volume keys                         | Raise, lower, or mute audio             |
| Super+Enter                         | Open Ghostty                            |
| Super+Shift+F                       | Open Files (Nautilus)                   |
| Super+Q                             | Close the focused window                |
| Super+F                             | Toggle window maximization              |
| Super+V                             | Toggle floating for the focused window  |
| Super+arrow                         | Change window focus                     |
| Super+1 through Super+9             | Switch workspace                        |
| Super+Shift+1 through Super+Shift+9 | Move a window to a workspace            |
| Super+left mouse drag               | Move a window                           |
| Super+right mouse drag              | Resize a window or adjust a tiled split |

##### Troubleshooting

SSH into the streaming machine as the desktop user and run:

``` bash
systemctl status greetd
systemctl --user status noctalia sunshine
hyprctl --instance 0 monitors
journalctl -u greetd -b
journalctl --user -u noctalia -u sunshine -b
```

If greetd is running but `hyprctl` reports `no such instance`, check UWSM's
compositor startup logs:

``` bash
journalctl --user -u wayland-wm-env@Hyprland.service -u wayland-wm@Hyprland.service -b
```

For a headless session, also check display creation:

``` bash
systemctl --user status headless-display
journalctl --user -u headless-display -b
```

### Container and VM Images

Linux container and VM images can be built using
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

By default, these images provide SSH (key-only authentication), Fish, and CLI
development tools. A [Hyprland desktop](#hyprland-desktop) can be
enabled separately. Disk-backed VM images (`qcow` and `raw`) also enable Docker
and add the configured user to the `docker`, `dialout`, and `plugdev` groups.
Their udev rules grant `plugdev` access to common embedded debug probes and
native USB debug interfaces. VM guests grant passwordless sudo to `wheel` so
`voom nixos switch` can activate configurations through the normal user. Images
are [voom](https://github.com/mjrusso/voom)-compatible (`cloud-init` with a
`NoCloud` datasource for bootstrap metadata; runtime coordination via the
`voom-control` virtiofs share mounted at `/run/voom`).

#### Running VM Images

[Voom](https://github.com/mjrusso/voom) manages VM creation, startup, SSH,
shutdown, and deletion. The system configuration installs it automatically.

Follow the Linux workflow below, or see [MacOS VM Images](#macos-vm-images)
for MacOS setup. The [update commands](#update-running-vms) apply to both.
MacOS images include the [bootstrap results](#bootstrap-and-validation);
Linux VMs need `home-bootstrap` after their first start.

##### Create a Linux VM

Run these commands from your system configuration repository.
[`bake-golden`](./scripts/bake-golden) builds the VM image and copies it to
`$VMS_DIR` (default `~/vms`) with a `.meta.json` metadata file. The commands
below assume `~/vms`; adjust the paths if you set `VMS_DIR` or `--output-dir`.
This example uses an x86_64 Linux host and a qcow2 image. For a MacOS host,
follow [Build Linux images on a Mac](#build-linux-images-on-a-mac) and use
the resulting `.raw` image and metadata paths in the import command.

``` bash
nix run .#bake-golden -- --system x86_64-linux --format qcow
```

Import the image and create the VM:

``` bash
voom image import golden ~/vms/golden-x86_64-linux.qcow2 --meta ~/vms/golden-x86_64-linux.qcow2.meta.json

voom create my-vm --image golden
```

If the host uses Agent Vault, complete [Attach a New VM](#attach-a-new-vm)
while the VM is stopped. Then start the VM and run
[`home-bootstrap`](./scripts/home-bootstrap) inside it:

``` bash
voom start my-vm

voom ssh my-vm -- home-bootstrap
```

##### Build Linux images on a Mac

Linux VMs on MacOS use vfkit and require a `raw` image. Building that image
requires a Linux builder. The `aarch64-darwin@desktop` host enables
`nix.linux-builder` (see
[`hosts/darwin/default.nix`](./hosts/darwin/default.nix)), which spins up a
small aarch64-linux NixOS VM under vfkit and registers it as a remote
builder. If the builder is not available on a given host, bake on a host that
does have an available Linux builder, and rsync the result over:

``` bash
# On the host with Linux builder:
nix run .#bake-golden -- --format raw --system aarch64-linux

# From the other host:
rsync -aS --info=progress2 \
  <host-with-linux-builder>:~/vms/golden-aarch64-linux.raw{,.meta.json} \
  ~/vms/
```

`rsync -S` preserves sparseness so the copy doesn't allocate the full
virtual size on the destination.

`--system aarch64-linux` is redundant on aarch64 Linux hosts (bake-golden
defaults to the host arch). On x86_64 Linux hosts it triggers a cross-arch
build, which works because
[`hosts/nixos/default.nix`](./hosts/nixos/default.nix) sets
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.

##### Update running VMs

To update running NixOS and MacOS VMs, run the exported `voom-update` app:

``` bash
nix run .#voom-update                            # all guests
nix run .#voom-update -- --dry-run               # preview
nix run .#voom-update -- my-vm                   # specific VMs
```

System updates use the configuration flake in the current directory.
To run it from another directory, use the configuration path as both the app
source and the `--flake` argument:

``` bash
nix run /path/to/system-config#voom-update -- --flake /path/to/system-config
```

The script supports three phases:

| Phase | What it does |
|-------|--------------|
| `--nixos` | Rebuilds and switches NixOS guests onto the host checkout's configuration. |
| `--darwin` | Builds MacOS configurations on the host, copies closures over SSH, and activates them in the guest. |
| `--emacs` | Pulls the guest's `~/.emacs.d` clone, cloning it first if missing. |

With no phase flag, each guest runs its matching system phase, followed by
Emacs. Pass phase flags to run only those phases:

``` bash
nix run .#voom-update -- --nixos
nix run .#voom-update -- --darwin macos-test
nix run .#voom-update -- --emacs my-vm
```

Stopped guests and guests without a matching selected phase are skipped,
including explicitly named guests. The NixOS phase requires `nixosSwitch`,
reuses the last switched flake target, and otherwise derives the target from
the architecture and image format. MacOS guests use the Darwin target
recorded in the imported image's `bundle.json`.

Darwin updates build on the host, honor `--public-flake`, and copy the built
closure using Voom's SSH identity and connection settings. The guest updates
its system profile and runs the built `darwin-rebuild activate` as root using
passwordless sudo. No source checkout or GitHub credentials are needed in the
guest. These updates apply nix-darwin and Home Manager configuration; they do
not install a new MacOS release or change the VM's Apple identity. A local
GC root retains the built closure until transfer and activation finish.

Phases are independent: a failure in one doesn't stop the others, and the
summary names both the VM and the phases that failed (`failed: my-vm(emacs)`).

> [!NOTE]
>
> The `emacs` phase skips a guest whose `~/.emacs.d` has uncommitted changes,
> and reports that guest as failed. It pulls from
> [the repository](https://github.com/mjrusso/.emacs.d), so unpushed work on
> this host is not pushed to the guests.

To update a single NixOS VM directly with Voom, use:

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

##### NVIDIA GPU in a VM

A VM can have exclusive use of a host NVIDIA GPU, for example for CUDA
workloads. While the VM runs, the host and other VMs cannot use the GPU.

1. Set up the host as described in [PCI Passthrough](#pci-passthrough).

2. Install the NVIDIA driver in your VMs. In your system configuration
   repository's `flake.nix`, add this module to the `extraModules` of the
   x86_64 VM targets:

   ``` nix
   { hardware.nvidiaGuest.enable = true; }
   ```

   Add it to the `extraModules` of the `qcow` and `raw` image outputs too, so
   that VMs created from a newly baked image include the driver. Then update
   the running VMs with `voom-update`.

   The driver adds about 1 GB to each VM. Its kernel module stays unloaded in
   VMs without an NVIDIA GPU. Installing it in every VM means you can move the
   GPU from one VM to another without changing either VM's configuration.

3. Assign the GPU to the VM while the VM is stopped, then start the VM and
   check that it sees the GPU:

   ``` bash
   voom pci discover
   voom stop my-vm
   voom pci add my-vm gpu 0000:41:00
   voom start my-vm
   voom ssh my-vm -- nvidia-smi
   ```

   `voom pci discover` lists the host's PCI slots and whether each one can be
   assigned. A slot address, such as `0000:41:00`, assigns all of the GPU's
   functions. A function address, such as `0000:41:00.0`, assigns only that
   function; the GPU function alone is enough for compute workloads.

To move the GPU to another VM, stop the VM that it is assigned to, run `voom
pci remove my-vm gpu`, and then follow step 3 for the other VM. To return the
GPU to the host, also remove it from `nixosVfio` in `host-info.nix`, apply the
configuration, and reboot.

#### MacOS VM Images

[`bake-macos`](./scripts/bake-macos) installs MacOS from an Apple IPSW,
creates a user account, enables SSH, installs Nix, and applies a nix-darwin
and Home Manager configuration. It then boots the image with vfkit and
validates the guest before saving the bundle.

The builder requires:

- An Apple Silicon Mac running MacOS 27 or later.
- A logged-in graphical session.
- An Xcode toolchain with a MacOS 27 SDK.
- An SSH identity that works without prompting, directly or through ssh-agent.

##### Configure the image

Define `macosImage` next to `darwinConfigurations` in your system configuration
flake. The included template provides this output with placeholder URLs and
checksums:

``` nix
macosImage = {
  ipsw = {
    url = "https://.../UniversalMac_27_..._Restore.ipsw";
    sha256 = "<64-character SHA-256>";
  };
  nix = {
    url = "https://releases.nixos.org/nix/<version>/nix-<version>-aarch64-darwin.tar.xz";
    sha256 = "<64-character SHA-256>";
  };
  target = "aarch64-darwin@vm";
  sdkVersion = "27.0";
  cpuCount = 4;
  memoryMiB = 8192;
  diskGiB = 100;
  fontFamilies = [ ];
};
```

Choose a MacOS 27 or later IPSW and an official Nix binary distribution, and
set their URLs and SHA-256 checksums. Nix 2.26 or later is required on both
host and guest when using relative path inputs. Both downloads also accept
absolute `file://` URLs. Set `sdkVersion` to the exact version reported by
`xcrun --sdk macosx --show-sdk-version`; use `DEVELOPER_DIR` to select Xcode.
Commit the configuration and `flake.lock`. Add new files to Git before
building: Git flakes include only tracked files. Inputs must be locked remote
sources or relative paths within their containing source tree; host-local
absolute paths are rejected.

The template selects `darwinConfigurations."aarch64-darwin@vm"`. That
configuration grants the user passwordless sudo, disables computer sleep,
sets Fish as the login shell, and installs Ghostty terminal definitions.
The builder authorizes the public key in the `.pub` file beside `--identity`.
The builder creates the account with the password you supply. Every VM created
from the image starts with that password. Keep it in a password manager; you
will need it to log in through the graphical console or change the password.

##### Select host fonts (optional)

Font copying is disabled by default. To copy installed fonts into the guest,
select their family names in the flake:

``` nix
fontFamilies = [ "Berkeley Mono" ];
```

To override the list when building, pass `--font-family "Berkeley Mono"`.
Repeat `--font-family` to select several families, or pass `--no-host-fonts`
to disable copying. The builder searches `~/Library/Fonts` and `/Library/Fonts`,
matches embedded family names case-insensitively, and copies all matching
styles. Missing families are reported without failing the bake.

To list installed fonts and available license metadata without starting a
VM or evaluating a configuration flake:

``` bash
nix run .#bake-macos -- --list-host-fonts \
  | jq '.[] | {families, path, licenseUrls}'
```

Selection uses family names, not license metadata. Supported files are
`.otf`, `.ttf`, `.otc`, and `.ttc`; a selected collection is copied whole,
including its other faces. `/System/Library/Fonts` and app-private directories
are not searched.

Fonts are staged outside the Nix store and copied to the guest user's
`~/Library/Fonts` before Emacs warm-up. Each transfer is checked against its
SHA-256. Filenames, families, hashes, and available license metadata are
recorded under `hostFonts` in `image.json`. Fonts are transferred separately
from the configuration snapshot; the builder does not add them to Git.

##### Build the image

Run from the system configuration directory, or pass `--flake PATH`:

``` bash
nix run .#bake-macos -- --check
nix run .#bake-macos -- --identity ~/.ssh/id_ed25519
```

The builder asks you to enter and confirm the initial login password before
downloading VM artifacts or installing MacOS. Password input is hidden. For
unattended builds, keep a password file outside the configuration repository
and pass its path:

``` bash
nix run .#bake-macos -- --identity ~/.ssh/id_ed25519 \
  --password-file "$HOME/.config/voom/initial-password"
```

The file must contain a nonempty UTF-8 password, optionally followed by one
LF or CRLF line ending. Spaces are preserved; control characters and extra
lines are rejected. The builder leaves your file unchanged. It uses a
temporary copy with mode `0600` and removes that copy on success or failure.
The password is not written to manifests or logs, and the exported bundle
contains no plaintext password file.

Without an interactive terminal, `--password-file` is required. `--check` and
`--list-host-fonts` do not read or prompt for a password.

`--check` evaluates and validates `macosImage`. It may fetch flake inputs,
but does not download the IPSW or Nix archive or start a VM.

The default output is `$VMS_DIR/golden-aarch64-darwin`, with `VMS_DIR`
defaulting to `~/vms`. Use `--output` to choose another directory. The import
and validation examples below assume `~/vms/golden-aarch64-darwin`; adjust
their paths if you change the output location.

A successful bake atomically replaces an existing bundle after validation.
Before replacement, shut down any VM running directly from the existing
bundle. The builder locks its storage files and swaps the directories.
This requires filesystem support for MacOS directory swaps, such as APFS.
Failed builds and failed swaps leave the existing bundle intact. Unrelated
directories and symlink outputs are rejected.

The builder prints its workspace path when it starts. On failure, it retains
that directory, including the staged `image/` and any `provision.log`,
`vfkit.log`, and `bootstrap.log` files. The staged image may be incomplete;
retention does not mark it as validated. The temporary account-password file
is removed during cleanup. After diagnosing the failure, remove the retained
workspace manually to reclaim its disk space. Successful builds remove their
workspace after publication.

While bootstrap runs, follow its output from another terminal:

``` bash
tail -f /path/to/printed/workspace/bootstrap.log
```

##### Create and start a MacOS VM

Run these commands on the host to import the bundle and create a VM:

``` bash
voom image import macos "$HOME/vms/golden-aarch64-darwin" \
  --ssh-identity "$HOME/.ssh/id_ed25519"
voom create macos-example --image macos
```

MacOS guests support VM lifecycle operations, the graphical console, and SSH.
Voom-managed file sharing, application port forwarding, and egress/proxy
attachment are unsupported.

Start the VM and connect over SSH:

``` bash
voom start macos-example
voom ssh macos-example
```

The image already includes the results of `home-bootstrap`. You can
[change the login password](#change-the-login-password) in the guest session. To
update its configuration later, use [voom-update](#update-running-vms).

##### Change the login password

To change a VM's login password, run this command in its SSH session:

``` bash
/usr/bin/passwd
```

Enter the current password, then the new password twice. Passwordless sudo
cannot reset this account without its current password. If an older image
has an unknown password, rebuild it and create a new VM.

Run `exit` to return to the host shell. To open the VM's graphical display,
run this command on the host:

``` bash
voom gui macos-example
```

Log in with the username from `user-info.nix` and the chosen initial password,
or your new password if you changed it.

##### Validate the image with Voom (optional)

This check creates a disposable VM and verifies SSH, Nix, data persistence,
and Apple identity across a restart.

Run from your configuration repository on the Mac host:

``` bash
nix run .#verify-macos-voom -- \
  --voom "$(command -v voom)" \
  --bundle "$HOME/vms/golden-aarch64-darwin" \
  --identity "$HOME/.ssh/id_ed25519"
```

Logs and `evidence/result.json` are saved in the printed
`/tmp/voom-accept-*` directory.

##### Build details

###### Bootstrap and validation

After applying the configuration, the builder shuts down the guest and boots it
with standalone vfkit using NAT networking. It checks boot and configuration
before copying fonts and running `home-bootstrap` as the guest user. Bootstrap
output is saved as `bootstrap.log`. A bootstrap failure fails
the bake; `--provision-timeout` controls its timeout. Bootstrap does not sign
in to GitHub or install credentials. If the guest has `agent-vault-proxy`,
the builder uses its `direct` mode for bootstrap so public repository clones
work before runtime proxy login. Proxy passwords stay out of the base image.

Bootstrap clones the repositories' current HEADs. Their commit IDs and paths
within the guest home are recorded in `image.json` under
`bootstrap.repositories`. These IDs describe the image; later bakes may clone
different commits. Voom preserves `image.json` as `bundle.json` on import.

The standalone boot checks SSH key access, MacOS version, Nix, system
activation, passwordless sudo, Fish, and Ghostty terminal support. It also
verifies the chosen password through Open Directory's `ODRecord.verifyPassword`
API and checks that Secure Token is enabled. The check uses SSH key
authentication and sends the password through stdin. SSH password
authentication remains disabled. Failed password authentication or a missing
Secure Token fails the bake.

Between VM processes, the builder waits up to two minutes for Apple's VM
helper to release storage locks.

###### Source and toolchain

The builder transfers a Nix snapshot of the source to the guest and builds
with lock updates disabled. Downloads are cached under
`~/Library/Caches/bake-macos` and checked against their hashes on every use.

The native installer is compiled outside the Nix build sandbox with the
selected Apple SDK. The SDK version, Swift compiler, and vfkit version are
recorded in the bundle. The installed disk is not expected to be bit-for-bit
reproducible. See `--help` for other options.

###### Bundle contents

The bundle contains `disk.raw`, `HardwareModel`, `MachineIdentifier`,
`AuxiliaryStorage`, `image.json`, `restore.json`, `toolchain.json`, and boot
and bootstrap logs. Keep the disk and platform files together.
`restore.json` records Apple's minimum CPU count and minimum memory size
(in bytes). Voom requires both values and uses them as the minimum resource
allocations when creating VMs.

#### Voom Agent Vault

[Agent Vault](https://docs.agent-vault.dev/) is an open-source credential vault
and HTTP/HTTPS proxy. Agent Vault stores credentials on the host and adds them
to outbound requests that match configured services. Voom guests send requests
through the proxy without storing the actual credentials.

This section covers Linux hosts and Linux guests. For MacOS guests using a
Linux vault through a Mac host, see [Shared Agent Vault Access for MacOS
Guests](#shared-agent-vault-access-for-macos-guests).

The `services.voomAgentVault` module runs one Agent Vault instance for all Voom
VMs on a Linux host. The manager creates one Agent Vault agent and token for each
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
        C["Command<br/>session proxy and CA environment"]
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

    C -->|"HTTP(S) proxy<br/>192.168.127.1:3128"| G
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

##### Agent Vault Initial Setup

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
tunnel <user>@<host> 14321
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

GitHub API and Git-over-HTTPS requests require separate services because they
use different hosts and authentication flows. Choose one of the following
configurations for each vault. Different vaults can use different
configurations.

###### Single GitHub PAT

Use this configuration when one PAT authenticates all GitHub requests from the
vault. Add these credentials:

| Credential        | Value                        |
|-------------------|------------------------------|
| `GITHUB_TOKEN`    | The personal access token    |
| `GITHUB_USERNAME` | The GitHub account user name |

Add the API service:

| Setting          | Value            |
|------------------|------------------|
| Name             | `github-api`     |
| Host             | `api.github.com` |
| Authentication   | Bearer           |
| Token credential | `GITHUB_TOKEN`   |

Add the Git smart HTTP service:

| Setting             | Value             |
|---------------------|-------------------|
| Name                | `github-git`      |
| Host                | `github.com`      |
| Authentication      | Basic             |
| Username credential | `GITHUB_USERNAME` |
| Password credential | `GITHUB_TOKEN`    |

The Basic-auth service selects `GITHUB_USERNAME` as a credential. The field
does not accept the user name as a literal value. Do not add substitutions to
either service in this configuration. The guest session gives `gh` the
nonsecret placeholder `GH_TOKEN=__github_token__` because `gh` requires the
variable. The API service replaces the complete Bearer header with the stored
token. The Git service replaces the complete Basic header with the stored user
name and token.

###### Multiple GitHub PATs

Use this configuration when different GitHub organizations require different
PATs. Add one PAT credential per organization and at least one user-name
credential. For an organization named `some-org`, use names such as:

| Credential                | Value                        |
|---------------------------|------------------------------|
| `GITHUB_USERNAME`         | The GitHub account user name |
| `GITHUB_SOME_ORG_PAT`     | The PAT for `some-org`       |
| `GITHUB_ANOTHER_ORG_PAT`  | The PAT for `another-org`    |

Credential keys accept uppercase letters, numbers, and underscores. Keep a
hyphen in the GitHub organization path, but replace it with an underscore in
the credential key and the recommended placeholder.

Add one API service shared by all of the PATs:

| Setting        | Value            |
|----------------|------------------|
| Name           | `github-api`     |
| Host           | `api.github.com` |
| Authentication | Passthrough      |

Add one substitution for each PAT:

| Credential               | Placeholder                    | Target |
|--------------------------|--------------------------------|--------|
| `GITHUB_SOME_ORG_PAT`    | `__github_some_org_pat__`      | Header |
| `GITHUB_ANOTHER_ORG_PAT` | `__github_another_org_pat__`   | Header |

The web interface labels these settings **URL Substitutions**. Select only
**Header** for each substitution. Do not select **Path** or **Query**. The API
service must use Passthrough authentication. A Bearer service has one fixed
token credential and overrides the incoming header before a substitution can
select a PAT.

Add one Basic-auth Git service per organization:

| Setting             | Value                     |
|---------------------|---------------------------|
| Name                | `github-git-some-org`     |
| Host                | `github.com/some-org/*`   |
| Authentication      | Basic                     |
| Username credential | `GITHUB_USERNAME`         |
| Password credential | `GITHUB_SOME_ORG_PAT`     |

Repeat that service for each organization and select its corresponding PAT.
Keep the organization spelling and case identical to its GitHub URL. Do not
retain an unscoped `github.com` Basic-auth service unless the vault deliberately
needs a fallback PAT for other owners.

Set the matching nonsecret placeholder in each repository's `.envrc`, or in a
trusted parent directory that contains repositories for the same organization:

``` bash
export GH_TOKEN='__github_some_org_pat__'
```

Run `direnv allow` after reviewing the file. Set `GH_TOKEN`. Do not also set
`GITHUB_TOKEN`. `gh` puts the placeholder in its authorization header, and the
API service replaces it with the selected PAT. Git does not use this
substitution. Its organization-specific Basic-auth service selects the PAT
from the repository URL.

Use fine-grained PAT ownership and repository permissions as the security
boundary. The organization path only selects which credential Agent Vault
injects. It does not reduce that credential's GitHub permissions.

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

Before user sessions start, the guest validates the Voom egress manifest and
creates a runtime environment with the proxy and CA settings. Fish shells and
the systemd user manager load this environment. Commands started by Fish or a
systemd user service inherit the settings. Commands run inside `nix develop`
or direnv also inherit them. A development shell, `.envrc`, or program can
override or remove the inherited variables. Check the effective environment
when a command does not use the proxy.

An attached VM with an invalid manifest does not permit user sessions. A VM
without an attachment starts normally without the egress environment.

Use `proxy run` to apply the egress settings explicitly to a command or
to diagnose its environment:

``` bash
proxy run -- curl --fail https://api.github.com/user
```

The helper requires a readable explicit egress manifest and a valid
`XDG_RUNTIME_DIR`. Clients with a built-in root store can ignore the session CA
variables.

Proxy exclusions are defined in
[`packages/voom-egress-no-proxy.nix`](./packages/voom-egress-no-proxy.nix).
Excluded hosts receive no proxy-injected credentials.

GitHub CLI also requires a nonempty local `GH_TOKEN`. The session supplies the
nonsecret placeholder `__github_token__` when the variable is absent. This
default works with the single-PAT configuration. A multi-PAT vault must set its
organization-specific placeholder before it runs `gh`.

Agent Vault creates its CA when the service first starts. The host module
publishes only the public certificate at
`/var/lib/voom-agent-vault-public/ca.pem`. The `voom-agent-vault sync` command
configures Voom to copy that certificate into the attached guest as
`/run/voom/egress-ca.pem`. The guest combines it with the standard CA bundle.
You do not generate or install a separate CA for this integration.

The guest imports the egress CA into Chromium's NSS database during boot. If
Voom replaces the CA while the guest remains running, refresh the database with
`sudo systemctl restart voom-egress-trust.service` or restart the VM. Restarting
the service also regenerates the session CA bundle and removes the old NSS
entry when `/run/voom/egress-ca.pem` is absent.

Git and GitHub CLI use their normal packages. In guests, the Codex and Claude
launchers add `--yolo` and `--dangerously-skip-permissions`, respectively.
The VM is the isolation boundary for these agents. Host installations keep
their normal permission controls.

Run these commands normally:

``` bash
gh api user --jq .login
git fetch
codex
claude
```

Both Linux and MacOS guests provide the same commands for explicit proxy use
and direct access:

``` bash
proxy run -- gh api user --jq .login
proxy bypass -- curl https://example.com
```

In Linux guests with an enabled Voom egress attachment, new Fish shells load
the prepared proxy environment automatically. In MacOS guests with
`programs.agentVaultProxy` enabled, new Fish shells load authenticated proxy
settings after `agent-vault-proxy login`. Existing shells keep their previous
environment. Use `proxy run` to load the settings explicitly for one command.
Applications must support the proxy environment variables; this does not route
all guest traffic through the proxy. Configured `NO_PROXY` destinations are
still reached directly.

The guest configuration selects the backend: `voom-egress-run` on Linux and
`agent-vault-proxy run` on MacOS. Both use `voom-egress-skip` for `bypass`. On
MacOS, use `agent-vault-proxy login`, `agent-vault-proxy check`, and
`agent-vault-proxy env` for credential setup, diagnostics, and shell
configuration. Use `agent-vault-proxy trust` in a guest GUI terminal to install
the CA in System Keychain.

Remove the session egress environment for one command with:

``` bash
proxy bypass -- gh auth status
```

`proxy bypass` removes the inherited proxy and Agent Vault CA variables for the
command and its children. It also removes `GH_TOKEN` when its value is the
default placeholder `__github_token__`, preserving other values, including
multi-PAT placeholders. It leaves the parent shell, installed CA trust, and
guest attachment or tunnel unchanged. Direct requests cannot use credentials
held by Agent Vault. Application-specific proxy settings can still apply.

For a Fish session without the inherited proxy settings, skip the startup
configuration that would load them again:

``` bash
proxy bypass -- fish --no-config
```

Run `exit` to return to the parent shell. Other Fish startup configuration is
also skipped in this session. Run `proxy --help` for command syntax. The
wrapper preserves command arguments and exit status; bypass does not require a
proxy credential or an active proxy connection.

HAProxy allows 10 seconds to establish an upstream connection. It applies a
15-minute idle timeout to clients, servers, CONNECT tunnels, WebSockets, and
streaming requests. A client must create a new request or connection after an
idle connection closes.

##### Validate an Attachment

For a vault that uses one PAT, run these commands after you attach a VM:

``` bash
gh api user --jq .login
proxy run -- curl --fail https://api.github.com/user
git ls-remote https://github.com/<owner>/<private-repository>.git HEAD
git -C <repository> fetch
git -C <repository> push --dry-run origin HEAD
```

For a vault that uses multiple PATs, enter a repository directory whose
`.envrc` selects the intended PAT and run:

``` bash
gh api repos/<owner>/<private-repository> --jq .full_name
proxy run -- curl --fail \
  --header "Authorization: Bearer $GH_TOKEN" \
  https://api.github.com/repos/<owner>/<private-repository>
git ls-remote https://github.com/<owner>/<private-repository>.git HEAD
git fetch
git push --dry-run origin HEAD
```

Repeat the multi-PAT checks for every configured organization. All commands
must succeed. Use low-risk repositories for the Git tests. Confirm that each
request appears under the expected API or organization-specific Git service in
the Agent Vault request log. If the VM uses Git LFS or GitHub release uploads,
test those operations as well. When migrating an existing VM, do not remove its
guest credential until these checks pass.

##### Migrating an Existing VM

New VMs must not receive a GitHub credential. For an existing VM, first
[validate its attachment](#validate-an-attachment). Then identify how the guest
supplies its old credential without printing the credential value:

``` bash
proxy bypass -- gh auth status --hostname github.com
proxy bypass -- env | sed 's/=.*//' | grep -E '^(GH_TOKEN|GITHUB_TOKEN)$'
proxy bypass -- git config --show-origin --get-regexp '^credential\.' || true
```

If GitHub CLI stores the credential, remove it with:

``` bash
proxy bypass -- gh auth logout --hostname github.com
```

Remove real tokens supplied by shell configuration, environment files, Git
credential stores, or other guest secret mechanisms. Keep a multi-PAT
placeholder in `.envrc`. The placeholder is not a credential. Then start a new
shell.

Verify that direct authenticated access fails:

``` bash
proxy bypass -- gh api user --jq .login        # must fail
proxy bypass -- curl --fail https://api.github.com/user # must fail with HTTP 401
proxy bypass -- env GIT_TERMINAL_PROMPT=0 \
  git ls-remote https://github.com/<owner>/<private-repository>.git HEAD # must fail
```

Repeat [Validate an Attachment](#validate-an-attachment) normally. All brokered
requests must still succeed and appear under the services configured for the
vault in the Agent Vault request log.

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
The host service sets proxy limits to 200 requests per second, a burst of
2,000, and 256 concurrent requests per agent and vault across all hosts.
Other tiers retain the `default` profile's limits. The rate-limit lock
prevents changes through the web interface.

##### Backup and Recovery

The host backup excludes agent tokens, the operator session, and generated
HAProxy maps. Before each host restic backup, NixOS creates a consistent SQLite
snapshot and copies Agent Vault's encrypted CA state into
`/var/cache/agent-vault-backup`. Snapshot directories are mode `0750` and
files are mode `0640`, owned by `agent-vault` with group
`agent-vault-backup`. The host Restic service receives this group to read
the snapshots. A snapshot failure does not suppress the rest of the host
backup. Restic can use the last successful snapshot.

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
loopback bypass in the session environment:

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

#### Shared Agent Vault Access for MacOS Guests

MacOS guests authenticate with an access identity and password through one SSH
tunnel on their Mac host. Linux maps each identity to a vault and supplies that
vault's proxy-only Agent Vault token. Service credentials and Agent Vault
tokens stay on Linux; guests hold only their proxy access password.

Give each VM its own identity for individual revocation, or share an identity
among VMs that should lose access together. Multiple identities can use the
same vault. Disabling an identity closes existing connections by restarting the
shared Linux bridge, briefly interrupting every guest. Other identities can
reconnect immediately. No Voom integration is required.

##### Configuration

This reuses the Linux Agent Vault server. Complete [Agent Vault Initial
Setup](#agent-vault-initial-setup) to initialize its vaults and service
credentials. Keep `sharedProxy.enable` disabled until the runtime files below
are provisioned. The parent `services.voomAgentVault` must be enabled; its
`assignments` can be empty when no Linux guests use it.

On the Linux Agent Vault host:

``` nix
services.voomAgentVault.sharedProxy = {
  enable = true;
  vaults = {
    personal = { };
    work = { };
  };
  identities = {
    personal.vault = "personal";
    work.vault = "work";
  };
};
```

The example uses one shared identity per vault, with matching names. Each
identity has a separate password file. Add `personal-test.vault = "personal";`
for another independently revocable credential to the same vault. Several VMs
can log in with one identity. The guest cannot select a different vault by
changing its request headers. An empty identity map denies all requests.

On the Mac host, use its reserved LAN IPv4 address:

``` nix
services.agentVaultTunnel = {
  enable = true;
  host = "linux-host";
  listenAddress = "192.168.1.10";
};
```

In the MacOS guest configuration:

``` nix
programs.agentVaultProxy = {
  enable = true;
  url = "http://192.168.1.10:3128";
  caCertificate = ./certificates/agent-vault.pem;
};
```

Copy the Linux server's public certificate from
`/var/lib/voom-agent-vault-public/ca.pem` to the configured certificate path.
It can be committed to the configuration repository. Guest activation adds it
to the CA bundle. System Keychain trust requires the separate GUI step under
[Guest Login and Commands](#guest-login-and-commands). Proxy and CA variables
are set for shells. After login, new Fish shells load the proxy password from
the runtime credential file and supply `GH_TOKEN=__github_token__` when unset or
empty; existing values are preserved. Other shells can use `proxy run`. Add
direct destinations to `programs.agentVaultProxy.noProxy` with `lib.mkAfter`.

##### Provision Vault Tokens, Access Passwords, and the SSH Key

Run these commands in Bash. Have the updated public and system configuration
checkouts on both hosts. Git flakes exclude untracked files; add new files
to Git before building. They do not need to be committed for local builds.

On Linux, use the operator's existing Agent Vault session to create one
proxy-only agent per vault. Each vault listed under `sharedProxy.vaults`
must already exist and have its service credentials configured; Nix does not
create these vaults. Confirm them with `agent-vault vault list`; if necessary,
run `agent-vault auth login --address http://127.0.0.1:14321` as the operator.
Before enabling the bridge, provision any missing runtime files:

``` bash
(
  set -euo pipefail
  umask 077
  sudo install -d -m 0755 /var/lib/agent-vault-shared-proxy
  sudo install -d -m 0700 /var/lib/voom-agent-vault-secrets
  token_file=$(mktemp)
  trap 'rm -f "$token_file"' EXIT
  for vault in personal work; do
    destination="/var/lib/voom-agent-vault-secrets/macos-$vault-token"
    if sudo test -s "$destination"; then continue; fi
    agent-vault agent create "macos-$vault" --role no-access \
      --vault "$vault:proxy" --token-only > "$token_file"
    test -s "$token_file"
    sudo install -m 0600 "$token_file" "$destination"
  done
)
```

Each agent has instance role `no-access` and a `proxy` grant for just its
vault. To rotate `personal`, write the output of `agent-vault agent rotate
macos-personal --token-only` to a private temporary file, install it at
`/var/lib/voom-agent-vault-secrets/macos-personal-token`, and restart the Linux
bridge. Rotate other vaults individually using their agent names and token
paths. Keep tokens out of Nix values and guest images. If an agent already
exists but its token file is missing, use this rotation procedure for that
vault to recover it.

Generate a password for each configured access identity. This skips files
that already exist, so rerunning it preserves installed passwords:

``` bash
(
  set -e
  umask 077
  sudo install -d -m 0700 /var/lib/agent-vault-shared-proxy/passwords
  password_file=$(mktemp)
  trap 'rm -f "$password_file"' EXIT
  for identity in personal work; do
    password_path="/var/lib/agent-vault-shared-proxy/passwords/$identity"
    if sudo test -e "$password_path"; then continue; fi
    openssl rand -hex 32 > "$password_file"
    sudo install -m 0600 "$password_file" "$password_path"
  done
)
```

The default vault token path is
`/var/lib/voom-agent-vault-secrets/macos-VAULT-token`; the default access
password path is `/var/lib/agent-vault-shared-proxy/passwords/IDENTITY`.
Override `vaults.NAME.tokenFile` or `identities.NAME.passwordFile` for other
runtime paths. Nix stores paths and assignments, never the secret values. All
configured files must exist, including those for disabled identities. Use a
separate random password for each identity; share an identity when VMs should
share a password. Never use the Agent Vault owner or master password as a proxy
access password.

On the Mac host, generate a dedicated SSH key:

``` bash
sudo install -d -m 0700 /etc/agent-vault-tunnel
if ! sudo test -f /etc/agent-vault-tunnel/id_ed25519; then
  sudo ssh-keygen -t ed25519 -N '' -f /etc/agent-vault-tunnel/id_ed25519
fi
```

Verify that `ssh linux-host true` succeeds using a trusted host key, replacing
`linux-host` with `services.agentVaultTunnel.host`. On the Mac, append the
public key to Linux's root-owned authorized key file:

``` bash
set -o pipefail
sudo cat /etc/agent-vault-tunnel/id_ed25519.pub |
  ssh linux-host 'sudo -n tee -a /var/lib/agent-vault-shared-proxy/authorized_keys >/dev/null'
ssh linux-host 'sudo -n chmod 0644 /var/lib/agent-vault-shared-proxy/authorized_keys'
```

The Linux operator needs noninteractive sudo for this transfer. The SSH account
`agent-vault-tunnel` allows forwarding to the shared socket. It denies shell
sessions, TCP destinations, and reverse forwarding, and cannot read the token.

On the Mac, pin the Linux host key from an existing, verified `known_hosts`
entry. Run this in Bash, replacing `linux-host` with the literal
`services.agentVaultTunnel.host` value:

``` bash
(
  set -euo pipefail
  pin_file=$(mktemp)
  trap 'rm -f "$pin_file"' EXIT
  ssh-keygen -F linux-host -f "$HOME/.ssh/known_hosts" > "$pin_file"
  test -s "$pin_file"
  sudo install -m 0644 "$pin_file" /etc/agent-vault-tunnel/known_hosts
)
```

The tunnel uses these root-owned files and ignores user SSH configuration.

##### Deploy the Host and Guest Configurations

Before activation, compare the Linux server and committed public CA
[fingerprints](#agent-vault-troubleshooting). Replace the committed public
certificate if they differ.

From your system configuration repository, apply the Linux configuration
first, then the Mac host configuration. For a pinned public input, run this
on each host:

``` bash
nix run .#build-switch
```

To use a sibling public working tree, pass the override to both the launcher
and its rebuild command:

``` bash
nix run .#build-switch \
  --override-input nixos-config path:../nixos-config \
  -- --override-input nixos-config path:../nixos-config
```

On Linux, confirm the services are active and the intended identities are
enabled:

``` bash
sudo systemctl status --no-pager agent-vault.service agent-vault-shared-proxy.service
sudo agent-vault-access status
```

On the Mac host, check the listener and firewall rule using
[Tunnel Status and Restart](#tunnel-status-and-restart) and
[Firewall Checks](#firewall-checks), then update the running guest:

``` bash
nix run .#voom-update -- --darwin macos-example
```

For a sibling public working tree, use:

``` bash
nix run .#voom-update \
  --override-input nixos-config path:../nixos-config \
  -- --public-flake ../nixos-config --darwin macos-example
```

Complete [Guest Login and Commands](#guest-login-and-commands), then verify
authenticated API and private Git access. Test disable/enable and LAN
exclusion as described under [Firewall Checks](#firewall-checks). Repeat the
guest and LAN checks after rebooting the Mac.

##### Guest Login and Commands

After updating a guest, install its credential. From Bash on the Mac host,
replace `linux-host` and `macos-example` with the host and VM names:

``` bash
set -o pipefail
ssh linux-host 'sudo -n agent-vault-access export personal' | \
  voom ssh macos-example -- agent-vault-proxy login
```

The Linux operator must be allowed to run the export through noninteractive
sudo. Export writes a secret to stdout; pipe it directly to the guest rather
than displaying it. Login validates the input and atomically installs
`~/.config/agent-vault-proxy/credential.json` with mode `0600`. A failed
export or invalid input leaves an existing guest credential unchanged.
Login is per Unix user; run it as the guest account that will use the proxy.
Set `programs.agentVaultProxy.credentialFile` to use a different runtime path.

Repeat with the same identity for VMs that should share access, or export a
different identity for each VM. Credential copies, including those in VM
clones and backups, share the same access and revocation. Keep access
passwords out of Nix configuration and shared base images.

The guest installs `proxy` and `agent-vault-proxy`. Use `proxy run` and
`proxy bypass` for daily use on either guest OS; see
[Guest Commands](#guest-commands) for shared behavior and the bypassed Fish
session example. Use
`agent-vault-proxy` for login, diagnostics, and shell configuration. These
commands work without opening a new shell after an update:

``` bash
agent-vault-proxy check
proxy run -- gh api user --jq .login
proxy run -- git ls-remote https://github.com/OWNER/PRIVATE-REPO.git HEAD
proxy bypass -- curl -q https://example.com
```

For applications that use System Keychain, install the CA once from a terminal
in the guest's graphical session. Open the guest with `voom gui macos-example`
on the Mac host, then run this inside the guest:

``` bash
agent-vault-proxy trust
```

Approve the macOS authentication prompt. Repeat this step if the CA changes.
This works before proxy login. Keychain trust can require GUI authorization
even as root; command-line tools use the CA bundle installed during activation.

`agent-vault-proxy check` makes an HTTPS request through the configured proxy
to GitHub's `/user` API. Success prints `GitHub API: HTTP 200` and exits zero.
It uses the nonsecret default GitHub placeholder, ignores `NO_PROXY`, and
verifies TLS with the configured CA bundle. This checks the tunnel, Linux
bridge, vault authentication, CA, and default GitHub API credential. It
requires the vault's default GitHub API service to be configured. A vault using
only [organization-specific placeholders](#multiple-github-pats) can reject
this check even when the tunnel works. For that vault, set the intended
`GH_TOKEN` placeholder and use `proxy run -- gh api repos/OWNER/REPO`. Check
other services separately.

On MacOS, `proxy run` sets the configured proxy, bypass list, and CA variables
for one command. It preserves an existing `GH_TOKEN`, including
organization-specific placeholders, and supplies the default placeholder when
absent or empty. It replaces inherited proxy settings, including `NO_PROXY=*`,
and clears `ALL_PROXY` and `all_proxy`. The child command's arguments and exit
status are preserved. Missing credentials or files accessible to other users
cause `proxy run` and `agent-vault-proxy check` to fail.

New Fish shells load the credential automatically. For an existing Bash shell,
use `eval "$(agent-vault-proxy env)"`; for Fish, use `agent-vault-proxy env
--fish | source`. The `env` output contains the proxy password; do not paste it
into logs or support messages. Use `proxy run` to read the current credential
without changing the parent shell.

`proxy bypass` works before login and when the tunnel is unavailable. It
preserves any installed System Keychain trust. Applications already running
need to be restarted to receive new settings. Authenticated proxy URLs in a
process's environment contain the access password. Avoid publishing environment
dumps or verbose HTTP traces.

After validating brokered API and private Git access, remove any existing
guest-held GitHub credentials using [Migrating an Existing
VM](#migrating-an-existing-vm). The `proxy bypass --` commands work on both
guest OSes; the guest checks above replace Linux attachment validation. Proxy
login does not remove old service credentials.

##### Disable, Enable, and Rotate Access

On Linux:

``` bash
sudo agent-vault-access status
sudo agent-vault-access disable personal
sudo agent-vault-access enable personal
```

Status lists each configured identity, its vault, and whether access is
enabled. It does not check service health. Disable writes a persistent hold
under `/var/lib/agent-vault-shared-proxy/disabled/` and restarts the bridge,
closing active CONNECT tunnels as well as other requests. The hold survives
service restarts, host reboots, and configuration rebuilds; `enable` removes it
and restarts the bridge. Both operations briefly interrupt every identity. All
VMs sharing the disabled identity lose access together. The Mac tunnel can stay
running.

To replace an access password, disable its identity, generate and install a new
password in its configured file, repeat guest login for each VM using that
identity, then enable it. The provisioning loop above skips existing password
files; replace the chosen file explicitly when rotating. Export and login work
while access is disabled; requests remain denied until enabled. Old copies will
receive HTTP 407. To move an identity to another vault, change its `vault`
assignment and apply the Linux configuration; no guest change is needed.

The bridge logs the authenticated access identity. Agent Vault sees the vault's
proxy-only agent, so its request logs and per-agent rate limits are shared by
all access identities assigned to that vault.

##### Recover MacOS Proxy Access

With the default paths, the Linux host backup includes Agent Vault's database
and encrypted CA state, but omits the shared proxy's vault tokens, access
passwords, authorized keys, and disabled-marker directory. Guest backups also
do not include the Mac host's SSH key or host-key pin. Keep protected copies of
runtime files and holds, or plan to recreate them.

After restoring the Linux host, keep `sharedProxy.enable` disabled until you
have restored or rotated the vault tokens, restored or replaced the access
passwords, and restored the disabled markers. If the hold state is unknown,
create a marker for every configured identity under
`/var/lib/agent-vault-shared-proxy/disabled/` before enabling the bridge.
Enable identities individually after review. `voom-agent-vault sync` manages
Linux VM attachments; it does not recreate these MacOS access files.

Restore or reprovision the Mac host's SSH key and verified host-key pin using
the provisioning steps above. Repeat guest login after changing passwords.
MacOS guest backups include the runtime credential under `/Users`; restoring or
cloning one preserves that identity's access. Use a separate identity for a
restored VM that needs independent revocation.
After recreating a guest, repeat the GUI trust step for applications that use
System Keychain.

##### Tunnel Status and Restart

On the Mac host:

``` bash
sudo launchctl print system/org.nixos.agent-vault-tunnel
sudo /usr/sbin/lsof -nP -iTCP:3128 -sTCP:LISTEN
sudo tail -n 50 /var/log/agent-vault-tunnel.log
```

Look for `state = running` and a PID in the launchd output, and an `ssh`
listener at `192.168.1.10:3128`. A running supervisor or open listener does
not prove that Linux can serve requests; run `agent-vault-proxy check` in a
guest to test that path.

To restart the shared tunnel:

``` bash
sudo launchctl kill SIGTERM system/org.nixos.agent-vault-tunnel
```

The supervisor closes SSH and exits. Launchd starts it again; allow about
15 seconds, then repeat the status and guest checks. A restart interrupts
requests from every guest.

On Linux, inspect the bridge and Agent Vault server:

``` bash
sudo systemctl status agent-vault-shared-proxy.service agent-vault.service
sudo journalctl -u agent-vault-shared-proxy.service -b -n 50 --no-pager
sudo journalctl -u agent-vault.service -b -n 50 --no-pager
```

Restart the bridge after replacing a vault token or to recover a failed bridge:

``` bash
sudo systemctl restart agent-vault-shared-proxy.service
```

Restarting `agent-vault.service` also restarts its bridge. The Mac SSH
connection can remain running across a bridge restart.

##### Agent Vault Troubleshooting

Start with `agent-vault-proxy check` in the guest, then inspect the Mac log
and Linux services above. Use the configured address and port in commands
below; `192.168.1.10:3128` is an example.
Inspect request records in Agent Vault's web interface; see
[Agent Vault Initial Setup](#agent-vault-initial-setup) for the administrator connection.

| Symptom | Check |
|---------|-------|
| `proxy: command not found` | Update the guest configuration. On MacOS, enable `programs.agentVaultProxy`; check that `/run/current-system/sw/bin` is on `PATH`. |
| `agent-vault-proxy: command not found` | Update the guest configuration and check that `/run/current-system/sw/bin` is on `PATH`. |
| Connection refused or curl error 7 | Inspect the Mac service, listener, and log. Check that the guest URL uses the Mac's LAN address. Guest `127.0.0.1` points to the guest. |
| Connection timeout or curl error 28 | Confirm the Mac still owns the configured IP. On the Mac, `/sbin/route -n get 192.168.1.10` must show `interface: lo0`. Check the PF rules below. |
| `Could not find service` from launchctl | The host configuration has not loaded the daemon. Apply the Mac host configuration; a guest update does not install host services. |
| `Address already in use` in the Mac log | Use `lsof` above to identify the listener. Stop the conflicting service before restarting the tunnel. |
| `Can't assign requested address` in the Mac log | The Mac's IP changed. Restore its reserved IP or update both the host listener and guest URL. |
| `Permission denied (publickey)` in the Mac log | Check the dedicated key and Linux authorized key as described below. The tunnel does not use your SSH agent. |
| `Host key verification failed` in the Mac log | Compare the pinned key with the Linux host's key through a trusted connection. Replace the pin only after verifying the change. |
| `channel ... open failed` or a missing socket in the Mac log | Check the Linux bridge service and `/run/agent-vault-shared-proxy/proxy.sock`. If the bridge is inactive, run `sudo systemctl start agent-vault-shared-proxy.service`. SSH can listen before this socket exists. |
| `administratively prohibited` in the Mac log | Apply the Linux SSH configuration. It must allow the tunnel account to forward to `/run/agent-vault-shared-proxy/proxy.sock`. |
| No proxy credential or private-file error | Repeat guest login. Check `ls -l ~/.config/agent-vault-proxy/credential.json`; it must be a private regular file. Use `chmod 0600` to fix permissions. Do not print its contents. |
| HTTP 407 or curl error 56 during CONNECT | On Linux, run `sudo agent-vault-access status`. Check the identity is enabled and assigned to the intended vault. Repeat guest login after a password change. Check bridge and Agent Vault logs: if the bridge accepted the identity but upstream refused it, confirm that vault's runtime token is current and has the vault's `proxy` grant. Restart the bridge after replacing a token. |
| Linux service reports a missing credential file | Provision every configured vault token and access password, even for disabled identities. Run `sudo journalctl -u agent-vault-shared-proxy.service -b -n 50 --no-pager` to find the path, then restart the bridge. |
| HTTP 401 or 403 from GitHub | Check the vault agent, service match, placeholder, and credential injection in Agent Vault's request log. A multi-PAT vault may require an organization-specific placeholder instead of the default used by `check`. Check the GitHub credential's validity and permissions. |
| Certificate verification failure or curl error 60 | Compare the committed public CA with the Linux server's current CA. Update the certificate and guest configuration after a CA change. Keep TLS verification enabled. |
| `SecTrustSettingsSetTrustSettings` reports no user interaction possible | Run `agent-vault-proxy trust` from a terminal in the guest's graphical session and approve the macOS prompt. Update the guest configuration if this occurs during activation. |
| `check` works but another command fails | Try `proxy run -- COMMAND`. If it works, inspect the command's inherited environment. Otherwise check its proxy support, vault service rules, and credential placeholder. A private Git request also needs the Git-over-HTTPS service. |

For SSH authentication failures, inspect file ownership and permissions without
printing the private key or token. On the Mac:

``` bash
sudo ls -ld /etc/agent-vault-tunnel
sudo ls -l /etc/agent-vault-tunnel/id_ed25519 /etc/agent-vault-tunnel/known_hosts
sudo ssh-keygen -lf /etc/agent-vault-tunnel/id_ed25519.pub
sudo ssh-keygen -lf /etc/agent-vault-tunnel/known_hosts
```

The directory must be root-owned with mode `0700`; the private key must be
root-owned with mode `0600`. On Linux:

``` bash
sudo ls -ld /var/lib/agent-vault-shared-proxy
sudo ls -l /var/lib/agent-vault-shared-proxy/authorized_keys
sudo ssh-keygen -lf /var/lib/agent-vault-shared-proxy/authorized_keys
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo ls -ld /run/agent-vault-shared-proxy
sudo ls -l /run/agent-vault-shared-proxy/proxy.sock
```

Compare the Mac public key fingerprint with `authorized_keys`, and the pinned
host key with Linux's host key of the same type. The runtime socket directory
belongs to `agent-vault-shared-proxy:agent-vault-tunnel` with mode `0750`;
the socket has mode `0660`.

For certificate failures, compare the SHA-256 fingerprints. On Linux:

``` bash
openssl x509 -in /var/lib/voom-agent-vault-public/ca.pem -noout -sha256 -fingerprint
```

In the guest configuration checkout:

``` bash
openssl x509 -in certificates/agent-vault.pem -noout -sha256 -fingerprint
```

If they differ, replace the committed public certificate and update the
guest. If `check` succeeds but a MacOS application reports an untrusted CA,
run `agent-vault-proxy trust` in a guest GUI terminal to install System Keychain
trust. The check uses the CA bundle; applications can use the Keychain or their
own trust store.

##### Firewall Checks

The tunnel installs this restriction under `com.apple/agent-vault-tunnel`:

``` text
block drop in quick on ! lo0 inet proto tcp from any to 192.168.1.10 port = 3128
```

Each guest's gvproxy reaches the Mac's own LAN address through `lo0`. The
rule blocks connections arriving from other machines. Inspect it on the Mac:

``` bash
sudo /sbin/pfctl -s info
sudo /sbin/pfctl -sr
sudo /sbin/pfctl -a com.apple/agent-vault-tunnel -sr
```

PF must be enabled, the main ruleset must contain
`anchor "com.apple/*" all`, and the child anchor must contain the restriction
for the configured address and port. The `No ALTQ support in kernel` message
is harmless. If the main anchor is missing, inspect `/etc/pf.conf` and restore
the host's PF configuration before restarting the tunnel. The daemon loads
only its own child anchor.

The supervisor checks PF after each one-second SSH wait. If PF is disabled,
the anchor disappears, or the restriction changes, it closes SSH and launchd
retries. Detection is periodic; a firewall change can briefly precede tunnel
shutdown. Stopping the service leaves the block rule installed.

After setup and after a Mac reboot, run the guest check and a private Git
request. Confirm `macos-personal` or `macos-work` and the intended vault in
Agent Vault's request log. The bridge log records the access identity without
its password. Test revocation with `disable`, confirm an existing proxy
session closes and new requests fail, then `enable` and rerun the guest check.
From a separate LAN machine, this command must fail to connect:

``` bash
curl -q --noproxy '*' --connect-timeout 5 --max-time 6 \
  --output /dev/null http://192.168.1.10:3128/
```

Any HTTP response means the listener is reachable from that machine. A
successful public Git request alone does not verify credential injection.

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
with _home-manager_. `bake-macos` runs it inside the guest before publishing the
image; Linux baking leaves it as a manual step after the VM's first start.

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
which must be manually installed on normal hosts and Linux guests. `bake-macos`
can copy it and other installed host fonts when selected through
`macosImage.fontFamilies` or `--font-family`.

#### Emacs

Emacs (see [overlays/emacs/](./overlays/emacs)) is installed via Nix from stock
nixpkgs, with a few additional packages and a custom MacOS app icon by [Darrin
Henein](https://darrinhenein.com/blog/emacs-icon/).

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
> Git flakes copy tracked files to the Nix store. Run `git add` for new files
> before `nix run .#build` or `nix run .#build-switch`; untracked files are
> ignored. The files do not need to be committed.

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
old generations that fall outside of its keep policy. It also deletes GC roots,
such as `result` symlinks and `.direnv` shells. It then runs a store garbage
collection. Pass `--no-direnv` to keep `.direnv` shells, or `--no-gcroots` to
keep all GC roots.

To preview what would be removed before committing to it:

``` bash
nh clean all --dry
```

Set an explicit retention policy to keep generations available for rollback:

``` bash
nh clean all --keep 5 --keep-since 7d
```

`--keep` sets how many recent generations to retain per profile, and
`--keep-since` retains anything newer than the given age regardless of count.

### Disk usage

[`disk-usage`](./scripts/disk-usage) lists what uses disk space and prints a
command to free each item. It does not delete anything. Every host installs
it. It reports:

- free space and the largest entries in `$HOME`
- package manager caches, Rust `target` directories, `node_modules`, and the
  systemd journal
- stopped Docker containers, and Docker images and volumes that no container
  uses
- Nix store paths, grouped by what references them: nothing, a running
  process, or a GC root

``` bash
disk-usage
# Optional flags: --top N (home entries to list), --min SIZE (default 100M)
```

If it cannot read a directory, it marks that size as incomplete and prints a
`sudo` command to rerun it. Under `sudo`, it still reports on your home
directory.

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
