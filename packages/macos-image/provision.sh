#!/bin/sh
set -eu

flake_ref=$1
system_attr=$2
export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin
cd "$HOME/voom-image-build"

tar xf source.tar
tar xf nix.tar.xz
set -- ./nix-*-aarch64-darwin/install
test "$#" -eq 1
"$1" --daemon --yes --no-channel-add

for file in /etc/bashrc /etc/zshrc /etc/nix/nix.conf; do
  if test -f "$file"; then
    sudo -n mv "$file" "$file.before-darwin"
  fi
done

nix --extra-experimental-features 'nix-command flakes' build \
  --no-update-lock-file --out-link system "$system_attr"
sudo -n ./system/sw/bin/darwin-rebuild switch --flake "$flake_ref" --no-update-lock-file
sudo -n rm /etc/sudoers.d/voom-image-bootstrap
