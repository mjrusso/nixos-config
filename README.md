# NixOS System Configurations

Initially built from the following template:
https://github.com/dustinlyons/nixos-config

Note that the above template uses
[nix-homebrew](https://github.com/zhaofengli/nix-homebrew) to manage the
Homebrew installation. I've removed that from here (at least for now) as I
don't think it's worth the extra complexity (especially since Nix is
dramatically reducing my reliance on Homebrew). Note that I'm still using
[nix-darwin](https://github.com/LnL7/nix-darwin/)'s Homebrew-related features;
it does not, however, automatically install Homebrew. **UPDATE:** I've run into
some issues and am not using any of nix-darwin's Homebrew-related features.
I'll manage Homebrew separately for now.

Also see: https://github.com/mitchellh/nixos-config

## Manual Setup

### Fish

Fish needs to be manually set as the login shell:

``` bash
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells
chsh -s ~/.nix-profile/bin/fish
```

See:

- https://github.com/LnL7/nix-darwin/issues/811
- https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1782971499
- https://github.com/nix-community/home-manager/issues/1226


### Homebrew

I use Homebrew for a few dependencies on Mac. (Homebrew must be manually
installed, as per the [official installation instructions](https://brew.sh/).

### Emacs

On Mac, I use
[homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus).

As per the note above, Homebrew is not managed via nix-darwin, and dependencies
must be installed manually:


``` bash
brew tap d12frosted/emacs-plus
brew install emacs-plus@30 --with-native-comp
brew install cmake libtool # needed for vterm
```
