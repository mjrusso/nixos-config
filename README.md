# NixOS System Configurations

Initially built from the following template: https://github.com/dustinlyons/nixos-config

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

Fish needs to be manually set as the login shell:

``` bash
echo /run/current-system/sw/bin/fish | sudo tee -a /etc/shells
chsh -s /run/current-system/sw/bin/fish
```

(See https://github.com/LnL7/nix-darwin/issues/811 and
https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1782971499 for more
details and discussion.)
