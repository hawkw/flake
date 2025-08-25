let
  rpool = "hekate-rpool";
  localDataset = "local";
  systemDataset = "system";
  userDataset = "user";
  cryptDataset = "crypt";
  zfs_fs = "zfs_fs";
  autosnapshot = "com.sun:autosnapshot";
  zfsContent = {
    type = "gpt";
    partitions = {
      zfs = {
        size = "100%";
        content = {
          type = "zfs";
          pool = rpool;
        };
      };
    };
  };
in
{
  disko.devices =
    {
      disk = {
        boot = {
          type = "disk";
          device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S3PZNF0JA28518H";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "2G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
            };
          };
        };
        nvme01 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079DDAA";
          content = zfsContent;
        };
        nvme02 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079E3F9";
          content = zfsContent;
        };
        nvme03 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079E4D6";
          content = zfsContent;
        };
        nvme04 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-WUS4C6432DSP3X3_A084A645";
          content = zfsContent;
        };
      };
      zpool =
        {
          ${rpool} = {
            type = "zpool";
            rootFsOptions = {
              # https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS
              acltype = "posixacl";
              atime = "off";
              compression = "zstd";
              mountpoint = "none";
              xattr = "sa";
            };
            mode = {
              topology = {
                type = "topology";
                vdev = [
                  {
                    mode = "raidz2";
                    members = [ "nvme01" "nvme02" "nvme03" "nvme04" ];
                  }
                ];
              };
            };
            # Dataset layout based on https://grahamc.com/blog/nixos-on-zfs/
            datasets = {
              ${localDataset} = {
                type = zfs_fs;
                options.mountpoint = "none";
              };
              "${localDataset}/nix" = {
                type = zfs_fs;
                mountpoint = "/nix";
                options = {
                  ${autosnapshot} = "false";
                };
              };
              ${systemDataset} = {
                type = zfs_fs;
                options.mountpoint = "none";
              };
              "${systemDataset}/root" = {
                type = zfs_fs;
                mountpoint = "/";
                options = {
                  ${autosnapshot} = "true";
                };
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${rpool}/${systemDataset}/root@blank$' || zfs snapshot ${rpool}/${systemDataset}/root@blank";
              };
              "${systemDataset}/var" = {
                type = zfs_fs;
                mountpoint = "/var";
                options = {
                  ${autosnapshot} = "false";
                };
              };
              ${cryptDataset} = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  encryption = "aes-256-gcm";
                  keyformat = "passphrase";
                  #keylocation = "file:///tmp/secret.key";
                  keylocation = "prompt";
                };
              };
              "${cryptDataset}/${userDataset}" = {
                type = zfs_fs;
                options.mountpoint = "none";
              };
              "${userDataset}/home" = {
                type = zfs_fs;
                mountpoint = "/home";
                options = {
                  ${autosnapshot} = "true";
                };
              };
            };
          };
        };
    };
}
