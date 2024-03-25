# NixOS System Configurations

> [!IMPORTANT]
>
> This is a WIP. The goal is to replace my
> [dotfiles](https://github.com/mjrusso/dotfiles).

## Setup and Installation

> [!NOTE]
>
> Mac only for now. I haven't tested this config on NixOS yet.

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

### Additional Setup

#### Fish

Fish needs to be manually set as the login shell:

``` bash
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells
chsh -s ~/.nix-profile/bin/fish
```

See:

- https://github.com/LnL7/nix-darwin/issues/811
- https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1782971499
- https://github.com/nix-community/home-manager/issues/1226

#### Fonts

I use [Berkely Mono](https://berkeleygraphics.com/typefaces/berkeley-mono/),
which must be manually installed.

#### Homebrew

I use Homebrew for a few dependencies on Mac. (Homebrew must be manually
installed, as per the [official installation instructions](https://brew.sh/).)

Note that [the template that this config is built off
of](https://github.com/dustinlyons/nixos-config) uses
[nix-homebrew](https://github.com/zhaofengli/nix-homebrew) to manage the
Homebrew installation. I've removed that from here (at least for now) as I
don't think it's worth the extra complexity (especially since Nix is
dramatically reducing my reliance on Homebrew). I'm not using
[nix-darwin](https://github.com/LnL7/nix-darwin/)'s Homebrew-related features
either; I'll just manage Homebrew separately for the time being.

#### Emacs

Emacs is installed via Nix, but [my
configuration](https://github.com/mjrusso/.emacs.d) is not part of this
repository (and not managed by _home-manager_).

To grab my config:

``` bash
git clone https://github.com/mjrusso/.emacs.d ~/.emacs.d
```

After installing Emacs, create an alias like so:

``` fish
osascript -e "tell application \"Finder\" to make alias file to posix file \"$(readlink $HOME/.nix-profile/Applications/Emacs.app)\" at POSIX file \"/Applications\" with properties {name:\"Emacs.app\"}"
```

(The `readlink` is necessary because because Mac aliases don't work on
symlinks, [as explained
here](https://github.com/NixOS/nix/issues/956#issuecomment-1367457122).)

There's certainly a better way to do this (automating via _home-manager_
activation, among other options); see
https://github.com/nix-community/home-manager/issues/1341 for more notes and
discussion.

Notes:

- consider automating symlinking for _.emacs.d_ (perhaps merge my [existing emacs repo](https://github.com/mjrusso/.emacs.d) into this one?)
 - https://www.reddit.com/r/NixOS/comments/197wnuy/help_making_a_direct_symlink_from_config_repo_to/
 - https://github.com/kenranunderscore/dotfiles/blob/310fb5694934010dbee577f5659a45a3144d3626/home-manager-modules/emacs/default.nix#L11-L17
 - https://discourse.nixos.org/t/how-to-manage-dotfiles-with-home-manager/30576
 - alternatively can I set it up this way? https://www.reddit.com/r/NixOS/comments/vj95cd/home_manager_and_separate_dotfiles_repo/

## Usage

_(These commands must be executed from the directory that this repo has been
cloned to.)_

To build and apply changes:

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

To update dependencies:

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
