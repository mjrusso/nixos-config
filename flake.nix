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

    mac-app-util = {
      url = "github:hraban/mac-app-util";
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
      mkRepoScriptApp = scriptName: system: {
        type = "app";
        program = "${
          (nixpkgs.legacyPackages.${system}.writeShellScriptBin scriptName ''
            export PATH=${
              nixpkgs.lib.makeBinPath (
                with nixpkgs.legacyPackages.${system};
                [
                  bash
                  coreutils
                  git
                  jq
                  nix
                  rsync
                ]
              )
            }:$PATH
            exec ${self}/scripts/${scriptName} "$@"
          '')
        }/bin/${scriptName}";
      };
      mkLinuxApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "bake-golden" = mkRepoScriptApp "bake-golden" system;
        "voom-update" = mkRepoScriptApp "voom-update" system;
      };
      mkDarwinApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "bake-golden" = mkRepoScriptApp "bake-golden" system;
        "voom-update" = mkRepoScriptApp "voom-update" system;
      };
    in
    {
      lib = import ./lib { inherit inputs; };
      devShells = forAllSystems devShell;
      apps =
        nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

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
