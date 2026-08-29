{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        basePackages = with pkgs; [
          git
          just
          curl
          nixpkgs-fmt
        ];

        # Interactive-only tooling: language servers, debuggers, watchers.
        # Anything added here stays out of the `ci` shell below.
        devPackages = with pkgs; [
        ];

        env = {
        };

        shellHook = ''
        '';

      in {
        devShells = {

          # A stripped-down dev shell, for use in CI environments.
          #
          # Example usage:
          #
          #     nix develop .#ci -c COMMAND
          ci = pkgs.mkShell {
            packages = basePackages;
            inherit env shellHook;
          };

          default = pkgs.mkShell {
            packages = basePackages ++ devPackages
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux
              (with pkgs; [ inotify-tools libnotify ])
              ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.terminal-notifier ];

            inherit env shellHook;
          };

        };
      });
}
