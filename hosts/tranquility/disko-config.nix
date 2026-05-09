let
  rpool = "tranquility-rpool";
  cryptDataset = "crypt";
  localDataset = "${cryptDataset}/local";
  systemDataset = "${cryptDataset}/system";
  userDataset = "${cryptDataset}/user";
  zfs_fs = "zfs_fs";
  optAutosnapshot = "com.sun:autosnapshot";
in
{
  disko.devices =
    {
      disk = {
        nvme0n1 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-CT1000P510SSD5_2525E9C382B2";
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
                  mountOptions = [ "umask=0077" "nofail" ];
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
              ${cryptDataset} = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  dnodesize = "auto";
                  encryption = "aes-256-gcm";
                  keyformat = "passphrase";
                  keylocation = "prompt";
                };
              };
              "${localDataset}" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  dnodesize = "auto";
                };
              };
              "${localDataset}/nix" = {
                type = zfs_fs;
                mountpoint = "/nix";
                options = {
                  ${optAutosnapshot} = "false";
                };
              };
              "${localDataset}/reserved" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  canmount = "off";
                  refreservation = "50G";
                  ${optAutosnapshot} = "false";
                };
              };
              "${systemDataset}" = {
                type = zfs_fs;
                options.mountpoint = "none";
              };
              "${systemDataset}/root" = {
                type = zfs_fs;
                mountpoint = "/";
                options = {
                  ${optAutosnapshot} = "true";
                  dnodesize = "auto";
                };
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${rpool}/${systemDataset}/root@blank$' || zfs snapshot ${rpool}/${systemDataset}/root@blank";
              };
              "${systemDataset}/var" = {
                type = zfs_fs;
                mountpoint = "/var";
                options = {
                  # Disable autosnapshot for `/var`.
                  ${optAutosnapshot} = "false";
                  dnodesize = "auto";
                };
              };
              "${systemDataset}/etc" = {
                type = zfs_fs;
                mountpoint = "/etc";
                options = {
                  # Disable autosnapshot for `/etc` --- this should all come
                  # from the nix store!
                  ${optAutosnapshot} = "false";
                  dnodesize = "auto";
                };
              };
              "${userDataset}" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  dnodesize = "auto";
                  # Snapshot all user datasets.
                  ${optAutosnapshot} = "true";
                };
              };
              "${userDataset}/home" = {
                type = zfs_fs;
                mountpoint = "/home";
                options = {
                  ${optAutosnapshot} = "true";
                };
              };
            };
          };
        };
    };
}
