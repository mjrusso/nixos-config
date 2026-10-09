{ config, lib, ... }:

let
  cfg = config.virtualisation.vfioPassthrough;
in
{
  options.virtualisation.vfioPassthrough = {
    pciIds = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}");
      default = [ ];
      example = [
        "10de:1e84"
        "10de:10f8"
      ];
      description = ''
        Vendor:device IDs that vfio-pci claims at boot, as reported by
        `lspci -nn`. List every function of each device. An ID matches every
        device that has it, so two identical cards are both claimed. An empty
        list disables passthrough.
      '';
    };

    hostDrivers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "xhci_pci"
        "nouveau"
      ];
      description = ''
        Kernel modules that would otherwise claim the devices. Each one gets a
        modprobe softdep that loads vfio-pci first.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User who runs the VMs; receives an unlimited memlock limit.";
    };
  };

  config = lib.mkIf (cfg.pciIds != [ ]) {
    boot.initrd.kernelModules = [
      "vfio_pci"
      "vfio"
      "vfio_iommu_type1"
    ];
    boot.kernelParams = [ "vfio-pci.ids=${lib.concatStringsSep "," cfg.pciIds}" ];
    boot.extraModprobeConfig = lib.concatMapStrings (
      driver: "softdep ${driver} pre: vfio-pci\n"
    ) cfg.hostDrivers;

    # uaccess only covers local seat sessions, so SSH users need a group.
    services.udev.extraRules = ''
      SUBSYSTEM=="vfio", GROUP="kvm", MODE="0660"
    '';

    # VFIO locks all guest RAM, so VMs fail to start under the default limit.
    security.pam.loginLimits = [
      {
        domain = cfg.user;
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
    ];
  };
}
