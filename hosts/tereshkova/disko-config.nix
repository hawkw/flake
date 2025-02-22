let
  rpool = "rpool";
  localDataset = "local";
  systemDataset = "system";
  userDataset = "user";
  zfs_fs = "zfs_fs";
  autosnapshot = "com.sun:autosnapshot";
in
{
  disko.devices =
    {
      disk = {
        nvme0n1 = {
          type = "disk";
          device = "nvme0n1";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "1G";
                type = "EF00";
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
                  pool = rpool;
                };
              };
            };
          };
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
              compression = "on";
              mountpoint = "none";
              xattr = "sa";
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
              ${userDataset} = {
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
