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

    voom = {
      # For local development, use `path:../voom` (assuming a sibling checkout).
      url = "github:mjrusso/voom";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, darwin, home-manager, nixpkgs, disko, mac-app-util, emacs-flake, voom, nixos-generators } @inputs:
    let
      userInfo = import ./user-info.nix;
      hostInfo = import ./host-info.nix;
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
          exec ${self}/apps/run ${system} ${scriptName} "$@"
        '')}/bin/${scriptName}";
      };
      mkLinuxApps = system: {
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
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
      mkVmModules = system: [
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
      mkVmImageMarkerModule = format: {
        environment.etc."mjr-vm-guest".text = "1\n";
        environment.etc."mjr-vm-image-format".text = "${format}\n";
      };
      mkSwitchableVmModules = system: format: (mkVmModules system) ++ [
        (mkVmImageMarkerModule format)
        ({ lib, modulesPath, pkgs, ... }: {
          imports = lib.optionals (format == "qcow") [
            "${toString modulesPath}/profiles/qemu-guest.nix"
          ];

          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            autoResize = true;
            fsType = "ext4";
          };

          boot = {
            growPartition = true;
            kernelParams = [ "console=ttyS0" "console=hvc0" ];
            initrd.availableKernelModules = lib.optionals (format == "raw") [ "uas" ];
            loader = {
              grub = {
                device =
                  if pkgs.stdenv.system == "x86_64-linux"
                  then lib.mkDefault "/dev/vda"
                  else lib.mkDefault "nodev";
                efiSupport =
                  if pkgs.stdenv.system != "x86_64-linux"
                  then lib.mkDefault true
                  else lib.mkDefault false;
                efiInstallAsRemovable =
                  if pkgs.stdenv.system != "x86_64-linux"
                  then lib.mkDefault true
                  else lib.mkDefault false;
              };
              timeout = lib.mkDefault 0;
            };
          };
        })
      ];
      mkSwitchableVmSystem = { system, format }: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = inputs // { inherit userInfo; };
        modules = mkSwitchableVmModules system format;
      };
      mkVmSystems = nixpkgs.lib.listToAttrs (nixpkgs.lib.flatten (map (system:
        [
          (nixpkgs.lib.nameValuePair "vm-${system}" (mkSwitchableVmSystem { inherit system; format = "qcow"; }))
          (nixpkgs.lib.nameValuePair "vm-${system}-qcow" (mkSwitchableVmSystem { inherit system; format = "qcow"; }))
          (nixpkgs.lib.nameValuePair "vm-${system}-raw" (mkSwitchableVmSystem { inherit system; format = "raw"; }))
        ]
      ) linuxSystems));
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
        specialArgs = inputs // { inherit userInfo hostInfo; };
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
      }) // mkVmSystems;

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
          generate = format:
            let
              imageFormat =
                if format == "raw" && system != "x86_64-linux"
                then "raw-efi"
                else format;
            in nixos-generators.nixosGenerate {
            inherit system;
            specialArgs = inputs // { inherit userInfo; };
            modules = (mkSwitchableVmModules system format) ++ nixpkgs.lib.optionals
              (format == "qcow" || format == "raw")
              [
                (mkVmImageMarkerModule format)
                # `virtualisation.diskSize = "auto"` undersizes the image for
                # our closure. Instead, pin an explicit size with headroom.
                # (Images are sparse, so the on-disk cost tracks actual usage.)
                { virtualisation.diskSize = 12288; }
              ];
            format = imageFormat;
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
