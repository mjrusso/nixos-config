# mjrusso's NixOS System Configurations

## Setup and Installation

> [!NOTE]
>
> Mac and Linux (non-NixOS) only for now. I haven't tested on NixOS yet.

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

### Additional Setup

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

- For Linux (non-NixOS) hosts, the Garnix cache must be configured manually.
Add the following to `/etc/nix/nix.conf` (or `~/.config/nix/nix.conf` if your
user is trusted):

    ```
    extra-substituters = https://cache.garnix.io
    extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=
    ```

    _(See [Garnix's documentation](https://garnix.io/docs/ci/caching/#caching).)_

Note that my [Emacs configuration](https://github.com/mjrusso/.emacs.d) is not
part of this repository (and not managed by _home-manager_).

To grab my config:

``` bash
git clone https://github.com/mjrusso/.emacs.d ~/.emacs.d
```

Notes:

- consider automating symlinking for _.emacs.d_ (perhaps merge my [existing emacs repo](https://github.com/mjrusso/.emacs.d) into this one?)
 - https://www.reddit.com/r/NixOS/comments/197wnuy/help_making_a_direct_symlink_from_config_repo_to/
 - https://github.com/kenranunderscore/dotfiles/blob/310fb5694934010dbee577f5659a45a3144d3626/home-manager-modules/emacs/default.nix#L11-L17
 - https://discourse.nixos.org/t/how-to-manage-dotfiles-with-home-manager/30576
 - alternatively can I set it up this way? https://www.reddit.com/r/NixOS/comments/vj95cd/home_manager_and_separate_dotfiles_repo/

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

### Container and VM Images

Container and VM images can be built using
[nixos-generators](https://github.com/nix-community/nixos-generators). The
following formats are supported:

| Format         | Description                                |
| -------------- | ------------------------------------------ |
| `lxc`          | LXC container tarball                      |
| `lxc-metadata` | LXC metadata tarball (needed for Incus)    |
| `docker`       | Docker/OCI image                           |
| `qcow`         | QEMU qcow2 disk image                      |
| `raw`          | Raw disk image                             |
| `iso`          | Bootable ISO image                         |

To build an image:

``` bash
nix build .#images.x86_64-linux.docker
nix build .#images.x86_64-linux.lxc
nix build .#images.aarch64-linux.qcow
```

The resulting image will be written to `./result`.

These images use a minimal NixOS configuration with SSH (key-only auth), Fish
shell, and CLI development tools — no GUI, no desktop services.

### Checks

To verify that all configurations (Darwin, NixOS, home-manager, and container
images) evaluate without errors:

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

### Updating dependencies

To update dependencies, run:

``` bash
nix flake update
```

## References

- https://github.com/dustinlyons/nixos-config
- https://github.com/mitchellh/nixos-config
- https://determinate.systems/posts/nix-direnv/
- https://mitchellh.com/writing/nix-with-dockerfiles

## Thanks

Thanks to [Dustin Lyons's starter
template](https://github.com/dustinlyons/nixos-config), which this
configuration is based off of.
