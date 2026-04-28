{ hostInfo, ... }:

{
  disko.devices = {
    disk.main = {
      device = hostInfo.nixosMainDisk;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = "1G";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options.ashift = "12";
      rootFsOptions = {
        compression = "zstd";
        atime = "off";
        xattr = "sa";
        acltype = "posixacl";
        mountpoint = "none";
        encryption = "aes-256-gcm";
        keyformat = "passphrase";
        keylocation = "prompt";
        "com.sun:auto-snapshot" = "false";
      };
      datasets = {
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options."com.sun:auto-snapshot" = "true";
        };
        home = {
          type = "zfs_fs";
          mountpoint = "/home";
          options."com.sun:auto-snapshot" = "true";
        };
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options."com.sun:auto-snapshot" = "false";
        };
        vms = {
          type = "zfs_fs";
          mountpoint = "/var/lib/libvirt/images";
          options = {
            recordsize = "64K";
            primarycache = "metadata";
            logbias = "throughput";
            "com.sun:auto-snapshot" = "false";
          };
        };
      };
    };
  };
}
