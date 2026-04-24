{
  description = "mjrusso's system configurations for MacOS, NixOS, and (non-NixOS) Linux systems";

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

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    workmux = {
      url = "github:raine/workmux";
    };
  };

  outputs = { self, darwin, home-manager, nixpkgs, disko, mac-app-util, emacs-flake, nixos-generators, workmux } @inputs:
    let
      userInfo = import ./user-info.nix;
      user = userInfo.user;
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      darwinSystems = [ "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs (linuxSystems ++ darwinSystems) f;
      devShell = system: let pkgs = nixpkgs.legacyPackages.${system}; in {
        default = with pkgs; mkShell {
          nativeBuildInputs = with pkgs; [ bashInteractive git ];
        };
      };
      mkApp = scriptName: system: {
        type = "app";
        program = "${(nixpkgs.legacyPackages.${system}.writeScriptBin scriptName ''
          #!/usr/bin/env bash
          PATH=${nixpkgs.legacyPackages.${system}.git}/bin:$PATH
          echo "Running ${scriptName} for ${system}"
          exec ${self}/apps/${system}/${scriptName}
        '')}/bin/${scriptName}";
      };
      mkLinuxApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "install" = mkApp "install" system;
      };
      mkDarwinApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
      };
      mkEvalCheck = { system, name, drvPath }:
        (nixpkgs.legacyPackages.${system}).runCommand "check-eval-${name}" {} ''
          echo "Configuration '${name}' evaluates successfully."
          echo "  drvPath: ${drvPath}"
          touch $out
        '';
    in
    {
      devShells = forAllSystems devShell;
      apps = nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

      # Darwin (MacOS) config.

      darwinConfigurations = {
        "aarch64-darwin@desktop" = darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = inputs // { systemType = "desktop"; inherit userInfo; };
          modules = [
            mac-app-util.darwinModules.default
            home-manager.darwinModules.home-manager
            ./hosts/darwin
          ];
        };

        "aarch64-darwin@laptop" = darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = inputs // { systemType = "laptop"; inherit userInfo; };
          modules = [
            mac-app-util.darwinModules.default
            home-manager.darwinModules.home-manager
            ./hosts/darwin
          ];
        };

        "aarch64-darwin@vm" = darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = inputs // { systemType = "vm"; inherit userInfo; };
          modules = [
            mac-app-util.darwinModules.default
            home-manager.darwinModules.home-manager
            ./hosts/darwin
          ];
        };
      };

      # NixOS config.

      nixosConfigurations = nixpkgs.lib.genAttrs linuxSystems (system: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = inputs // { inherit userInfo; };
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = { inherit userInfo; };
              users.${user} = import ./modules/nixos/home-manager.nix;
            };
          }
          ./hosts/nixos
        ];
      });

      # Linux (non-NixOS) config.

      homeConfigurations = nixpkgs.lib.genAttrs linuxSystems (system:
        home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.${system};
          extraSpecialArgs = inputs // { inherit userInfo; };
          modules = [
            ./hosts/linux
          ];
        }
      );

      # Container and VM image builds via nixos-generators.

      images = nixpkgs.lib.genAttrs linuxSystems (system:
        let
          containerModules = [
            home-manager.nixosModules.home-manager {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = { inherit userInfo; };
                users.${user} = import ./modules/container/home-manager.nix;
              };
            }
            ./hosts/container
          ];
          generate = format: nixos-generators.nixosGenerate {
            inherit system;
            specialArgs = inputs // { inherit userInfo; };
            modules = containerModules;
            inherit format;
          };
        in {
          lxc = generate "lxc";
          lxc-metadata = generate "lxc-metadata";
          docker = generate "docker";
          qcow = generate "qcow";
          raw = generate "raw";
          iso = generate "iso";
        }
      );

      # Evaluation checks — verifies all configurations evaluate without errors.
      # Uses the .drvPath interpolation trick so checks are buildable on any
      # platform (the runCommand wrapper is native; the drvPath forces full
      # cross-platform evaluation of the target config).

      checks = forAllSystems (system:
        let
          check = name: drvPath: mkEvalCheck { inherit system name drvPath; };

          darwinChecks = nixpkgs.lib.mapAttrs'
            (name: cfg: nixpkgs.lib.nameValuePair
              "darwin-${name}"
              (check "darwin-${name}" cfg.system.drvPath))
            self.darwinConfigurations;

          nixosChecks = nixpkgs.lib.mapAttrs'
            (name: cfg: nixpkgs.lib.nameValuePair
              "nixos-${name}"
              (check "nixos-${name}" cfg.config.system.build.toplevel.drvPath))
            self.nixosConfigurations;

          homeChecks = nixpkgs.lib.mapAttrs'
            (name: cfg: nixpkgs.lib.nameValuePair
              "home-${name}"
              (check "home-${name}" cfg.activationPackage.drvPath))
            self.homeConfigurations;

          imageChecks = nixpkgs.lib.foldl' (acc: imgSystem:
            acc // nixpkgs.lib.mapAttrs'
              (format: drv: nixpkgs.lib.nameValuePair
                "image-${imgSystem}-${format}"
                (check "image-${imgSystem}-${format}" drv.drvPath))
              self.images.${imgSystem}
          ) {} linuxSystems;

        in
          darwinChecks // nixosChecks // homeChecks // imageChecks
      );

  };
}
