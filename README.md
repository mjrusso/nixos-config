# mjrusso's NixOS System Configurations

## Setup and Installation

Start by editing [`user-info.nix`](./user-info.nix) to set your desired
username, full name, email address, and SSH public keys.

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
vm up emacs-test         # boot another VM (see networking notes below)
vm list                  # show state
vm ssh scratch           # SSH in
vm console scratch       # stream the serial log (live boot output)
vm up scratch --rebuild  # wipe disk, reinstall from current golden
vm down scratch          # graceful shutdown
vm rm scratch            # delete VM and all its state
```

`vm up` flags:

- `--no-wait` — launch the VM and return immediately, without waiting for SSH
  to come up. Useful when you want to observe the boot yourself (e.g.
  `vm console <name>` in another terminal).

The `vm` command drives two back-ends:

- **Linux hosts** (`x86_64` or `aarch64`) use qemu + KVM, configured with
  port-forwarded networking (SSH to `localhost:<allocated-port>`).
- **Darwin hosts** (`aarch64` or `x86_64`) use
  [vfkit](https://github.com/crc-org/vfkit) (which itself uses Apple's
  `Virtualization.framework` under-the-covers), configured with NAT networking
  with DHCP (SSH to the guest's assigned IP on port 22, as resolved from
  `/var/db/dhcpd_leases`).

Additional notes:

- The host architecture must match the image architecture in both cases, as
  cross-arch TCG emulation isn't wired up.
- `vm list` shows the effective SSH endpoint in the `SSH` column regardless of
  backend.
- `bake-golden` defaults to `qcow` on Linux and `raw` on Darwin; the `vm`
  script picks the matching disk extension automatically.
- `vm` is available on the `PATH`, so you can run it from anywhere.
- Per-VM state (disk, port, pidfile, serial log) lives under
  `$VMS_DIR/<name>/`.

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
