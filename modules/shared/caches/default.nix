{ pkgs, lib, ... }:
{
  nix.settings = {
    substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
      "https://cache.numtide.com"
      "https://cache.nixos.org/"
    ];
    trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };
}
