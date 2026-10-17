{
  description = "Shared modules and tools for mjrusso's system configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    emacs-flake = {
      url = "github:mjrusso/emacs-flake";
    };

    voom = {
      # For local development, use `path:../voom` (assuming a sibling checkout).
      url = "github:mjrusso/voom";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    herdlord = {
      # For local development, use `path:../herdlord` (assuming a sibling checkout).
      url = "github:mjrusso/herdlord";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [ "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs (linuxSystems ++ darwinSystems) f;
      devShell =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default =
            with pkgs;
            mkShell {
              nativeBuildInputs = with pkgs; [
                bashInteractive
                git
              ];
            };
        };
      mkApp = scriptName: system: {
        type = "app";
        program = "${
          (nixpkgs.legacyPackages.${system}.writeScriptBin scriptName ''
            #!/usr/bin/env bash
            PATH=${nixpkgs.legacyPackages.${system}.git}/bin:$PATH
            echo "Running ${scriptName} for ${system}"
            exec ${self}/apps/run ${system} ${scriptName} "$@"
          '')
        }/bin/${scriptName}";
      };
      mkRepoScriptApp = scriptName: system: extraPackages: {
        type = "app";
        program = "${
          (nixpkgs.legacyPackages.${system}.writeShellScriptBin scriptName ''
            export PATH=${
              nixpkgs.lib.makeBinPath (
                (with nixpkgs.legacyPackages.${system}; [
                  bash
                  coreutils
                  git
                  jq
                  nix
                  rsync
                ])
                ++ extraPackages
              )
            }:$PATH
            exec ${self}/scripts/${scriptName} "$@"
          '')
        }/bin/${scriptName}";
      };
      mkMacosImageCheck =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.runCommand "check-macos-image"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.shellcheck
            ];
          }
          ''
            python3 -m unittest discover -s ${./packages/macos-image} -p 'test_*.py'
            shellcheck ${./packages/macos-image/provision.sh} ${./scripts/bake-macos}
            touch $out
          '';
      mkVoomUpdateCheck =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.runCommand "check-voom-update"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.bash
              pkgs.jq
              pkgs.shellcheck
            ];
          }
          ''
            cd ${self}
            PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_voom_update.py'
            shellcheck scripts/voom-update
            touch $out
          '';
      mkLinuxApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "bake-golden" = mkRepoScriptApp "bake-golden" system [ ];
        "voom-update" = mkRepoScriptApp "voom-update" system [
          inputs.voom.packages.${system}.default
          nixpkgs.legacyPackages.${system}.openssh
        ];
      };
      mkDarwinApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "bake-golden" = mkRepoScriptApp "bake-golden" system [ ];
        "bake-macos" = mkRepoScriptApp "bake-macos" system (
          with nixpkgs.legacyPackages.${system};
          [
            python3
            openssh
            vfkit
          ]
        );
        "voom-update" = mkRepoScriptApp "voom-update" system [
          inputs.voom.packages.${system}.default
          nixpkgs.legacyPackages.${system}.openssh
        ];
      };
    in
    {
      lib = import ./lib { inherit inputs; };
      devShells = forAllSystems devShell;
      apps =
        nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

      packages = nixpkgs.lib.genAttrs linuxSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          agent-vault = pkgs.callPackage ./packages/agent-vault.nix { };
          disk-usage = pkgs.callPackage ./packages/disk-usage.nix { };
          voom-agent-vault = pkgs.callPackage ./packages/voom-agent-vault { };
          voom-egress-run = pkgs.callPackage ./packages/voom-egress-run.nix { };
          voom-egress-skip = pkgs.callPackage ./packages/voom-egress-skip.nix { };
          voom-shutdown = pkgs.callPackage ./packages/voom-shutdown.nix {
            voom = inputs.voom.packages.${system}.default;
          };
        }
      );

      checks.x86_64-linux = {
        macos-image = mkMacosImageCheck "x86_64-linux";
        voom-update = mkVoomUpdateCheck "x86_64-linux";
        voom-agent-vault = import ./tests/voom-agent-vault.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          voomPackage = inputs.voom.packages.x86_64-linux.default;
        };
        voom-egress = import ./tests/voom-egress.nix {
          inherit inputs;
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
      };

      checks.aarch64-darwin = {
        macos-image = mkMacosImageCheck "aarch64-darwin";
        voom-update = mkVoomUpdateCheck "aarch64-darwin";
      };

      # Starting points for new projects.

      templates = {
        dev-project = {
          path = ./templates/dev-project;
          description = "A nix-direnv .envrc, a flake with default and ci devShells, and a justfile";
        };
        system-config = {
          path = ./templates/system-config;
          description = "A system configuration flake that consumes mjrusso/nixos-config";
        };
      };
    };
}
