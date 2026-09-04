{
  description = "System configuration using mjrusso/nixos-config";

  inputs = {
    nixos-config.url = "github:mjrusso/nixos-config";
    nixpkgs.follows = "nixos-config/nixpkgs";
  };

  outputs =
    {
      self,
      nixos-config,
      nixpkgs,
      ...
    }:
    let
      userInfo = import ./user-info.nix;
      hostInfo = import ./host-info.nix;
      constructors = nixos-config.lib;
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [ "aarch64-darwin" ];
      allSystems = linuxSystems ++ darwinSystems;
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;

      mkEvalCheck =
        {
          system,
          name,
          drvPath,
        }:
        let
          evaluatedDrvPath = builtins.unsafeDiscardStringContext drvPath;
        in
        nixpkgs.legacyPackages.${system}.runCommand "check-eval-${name}" { } ''
          echo "Configuration '${name}' evaluates successfully."
          echo "  drvPath: ${evaluatedDrvPath}"
          touch $out
        '';

      mkVmSystems = system: {
        "vm-${system}-qcow" = constructors.mkVmConfiguration {
          inherit system userInfo;
          format = "qcow";
        };
        "vm-${system}-raw" = constructors.mkVmConfiguration {
          inherit system userInfo;
          format = "raw";
        };
      };
    in
    {
      apps = nixos-config.apps;
      devShells = nixos-config.devShells;

      darwinConfigurations = {
        "aarch64-darwin@desktop" = constructors.mkDarwinConfiguration {
          systemType = "desktop";
          inherit userInfo;
        };
        "aarch64-darwin@laptop" = constructors.mkDarwinConfiguration {
          systemType = "laptop";
          inherit userInfo;
        };
        "aarch64-darwin@vm" = constructors.mkDarwinConfiguration {
          systemType = "vm";
          inherit userInfo;
        };
      };

      nixosConfigurations =
        nixpkgs.lib.genAttrs linuxSystems (
          system:
          constructors.mkNixosConfiguration {
            inherit system userInfo hostInfo;
          }
        )
        // nixpkgs.lib.foldl' (acc: system: acc // mkVmSystems system) { } linuxSystems
        // {
          wsl-x86_64-linux = constructors.mkWslConfiguration {
            system = "x86_64-linux";
            inherit userInfo;
          };
        };

      homeConfigurations = nixpkgs.lib.genAttrs linuxSystems (
        system:
        constructors.mkHomeConfiguration {
          inherit system userInfo;
        }
      );

      images = nixpkgs.lib.genAttrs linuxSystems (
        system:
        nixpkgs.lib.genAttrs
          [
            "lxc"
            "lxc-metadata"
            "docker"
            "qcow"
            "raw"
            "iso"
          ]
          (
            format:
            constructors.mkImage {
              inherit system format userInfo;
            }
          )
      );

      checks = forAllSystems (
        system:
        let
          check = name: drvPath: mkEvalCheck { inherit system name drvPath; };

          darwinChecks = nixpkgs.lib.mapAttrs' (
            name: cfg: nixpkgs.lib.nameValuePair "darwin-${name}" (check "darwin-${name}" cfg.system.drvPath)
          ) self.darwinConfigurations;

          nixosChecks = nixpkgs.lib.mapAttrs' (
            name: cfg:
            nixpkgs.lib.nameValuePair "nixos-${name}" (
              check "nixos-${name}" cfg.config.system.build.toplevel.drvPath
            )
          ) self.nixosConfigurations;

          homeChecks = nixpkgs.lib.mapAttrs' (
            name: cfg:
            nixpkgs.lib.nameValuePair "home-${name}" (check "home-${name}" cfg.activationPackage.drvPath)
          ) self.homeConfigurations;

          imageChecks = nixpkgs.lib.foldl' (
            acc: imageSystem:
            acc
            // nixpkgs.lib.mapAttrs' (
              format: drv:
              nixpkgs.lib.nameValuePair "image-${imageSystem}-${format}" (
                check "image-${imageSystem}-${format}" drv.drvPath
              )
            ) self.images.${imageSystem}
          ) { } linuxSystems;
        in
        darwinChecks // nixosChecks // homeChecks // imageChecks
      );
    };
}
