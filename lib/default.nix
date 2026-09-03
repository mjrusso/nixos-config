{ inputs }:

let
  inherit (inputs)
    darwin
    disko
    home-manager
    mac-app-util
    nixos-generators
    nixpkgs
    ;

  mergeArgs = base: extra: extra // base;

  mkHomeManagerSettings =
    {
      userInfo,
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    {
      useGlobalPkgs = true;
      useUserPackages = true;
      sharedModules = extraHomeModules;
      extraSpecialArgs = mergeArgs { inherit userInfo; } extraSpecialArgs;
    };

  mkVmImageMarkerModule = format: {
    environment.etc."mjr-vm-guest".text = "1\n";
    environment.etc."mjr-vm-image-format".text = "${format}\n";
  };

  mkVmModules =
    {
      system,
      format ? null,
      userInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    let
      user = userInfo.user;
      imageModules =
        (nixpkgs.lib.optionals (format == "qcow" || format == "raw") [
          {
            virtualisation.docker.enable = true;
            users.users.${user}.extraGroups = [ "docker" ];
            time.timeZone = "America/New_York";
            boot.kernel.sysctl = {
              "vm.overcommit_memory" = 1;
              "vm.swappiness" = 10;
            };
            swapDevices = [
              {
                device = "/swapfile";
                size = 2048;
              }
            ];
          }
        ])
        ++ (nixpkgs.lib.optionals (format != null) [
          (mkVmImageMarkerModule format)
          (
            {
              lib,
              modulesPath,
              pkgs,
              ...
            }:
            {
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
                kernelParams = [
                  "console=ttyS0"
                  "console=hvc0"
                ];
                initrd.availableKernelModules = lib.optionals (format == "raw") [ "uas" ];
                loader = {
                  grub = {
                    device =
                      if pkgs.stdenv.system == "x86_64-linux" then lib.mkDefault "/dev/vda" else lib.mkDefault "nodev";
                    efiSupport = lib.mkDefault (pkgs.stdenv.system != "x86_64-linux");
                    efiInstallAsRemovable = lib.mkDefault (pkgs.stdenv.system != "x86_64-linux");
                  };
                  timeout = lib.mkDefault 0;
                };
              };
            }
          )
        ]);
    in
    [
      home-manager.nixosModules.home-manager
      {
        home-manager =
          (mkHomeManagerSettings {
            inherit userInfo extraHomeModules extraSpecialArgs;
          })
          // {
            users.${user} = import ../modules/container/home-manager.nix;
          };
      }
      ../hosts/container
    ]
    ++ imageModules
    ++ extraModules;

in
{
  mkDarwinConfiguration =
    {
      system ? "aarch64-darwin",
      systemType,
      userInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    darwin.lib.darwinSystem {
      inherit system;
      specialArgs =
        inputs
        // (mergeArgs {
          inherit systemType userInfo;
        } extraSpecialArgs);
      modules = [
        mac-app-util.darwinModules.default
        home-manager.darwinModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            sharedModules = extraHomeModules;
            extraSpecialArgs = mergeArgs { inherit userInfo; } extraSpecialArgs;
          };
        }
        ../hosts/darwin
      ]
      ++ extraModules;
    };

  mkNixosConfiguration =
    {
      system,
      userInfo,
      hostInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    let
      user = userInfo.user;
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs =
        inputs
        // (mergeArgs {
          inherit userInfo hostInfo;
        } extraSpecialArgs);
      modules = [
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
        {
          home-manager =
            (mkHomeManagerSettings {
              inherit userInfo extraHomeModules extraSpecialArgs;
            })
            // {
              users.${user} = import ../modules/nixos/home-manager.nix;
            };
        }
        ../hosts/nixos
      ]
      ++ extraModules;
    };

  mkHomeConfiguration =
    {
      system,
      userInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.${system};
      extraSpecialArgs =
        inputs
        // (mergeArgs {
          inherit userInfo;
        } extraSpecialArgs);
      modules = [ ../hosts/linux ] ++ extraHomeModules ++ extraModules;
    };

  mkVmConfiguration =
    {
      system,
      format ? "qcow",
      userInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs =
        inputs
        // (mergeArgs {
          inherit userInfo;
        } extraSpecialArgs);
      modules = mkVmModules {
        inherit
          system
          format
          userInfo
          extraModules
          extraHomeModules
          extraSpecialArgs
          ;
      };
    };

  mkImage =
    {
      system,
      format,
      userInfo,
      extraModules ? [ ],
      extraHomeModules ? [ ],
      extraSpecialArgs ? { },
    }:
    let
      imageFormat = if format == "raw" && system != "x86_64-linux" then "raw-efi" else format;
      imageModules = nixpkgs.lib.optionals (format == "qcow" || format == "raw") [
        (mkVmImageMarkerModule format)
        { virtualisation.diskSize = 12288; }
      ];
    in
    nixos-generators.nixosGenerate {
      inherit system;
      specialArgs =
        inputs
        // (mergeArgs {
          inherit userInfo;
        } extraSpecialArgs);
      modules =
        (mkVmModules {
          inherit
            system
            format
            userInfo
            extraModules
            extraHomeModules
            extraSpecialArgs
            ;
        })
        ++ imageModules;
      format = imageFormat;
    };
}
