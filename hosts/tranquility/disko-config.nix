let
  rpool = "tranquility-rpool";
  cryptDataset = "crypt";
  localDataset = "${cryptDataset}/local";
  systemDataset = "${cryptDataset}/system";
  userDataset = "${cryptDataset}/user";
  zfs_fs = "zfs_fs";

  # Each NVMe device gets its own 4G ESP plus a ZFS partition. lanzaboote signs
  # and installs the bootloader to *both* ESPs on every `nixos-rebuild` (its
  # primary `boot.loader.efi.efiSysMountPoint` plus
  # `boot.lanzaboote.extraEfiSysMountPoints`), so the system can boot from
  # either device if the other fails. The ZFS partitions are combined into a
  # single mirror vdev (`mode = "mirror"`).
  mkBootDisk = { name, id, esp }: {
    inherit name;
    value = {
      type = "disk";
      device = "/dev/disk/by-id/${id}";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            # lanzaboote stores a full signed UKI (kernel + initrd) per
            # generation; with `configurationLimit = 8` and this host's large
            # ZFS + clevis initrd, 4G leaves comfortable headroom and is
            # negligible on a 512G drive.
            size = "4G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = esp;
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
in
{
  # enable disko-zfs to manage ZFS datasets from this configuration whenever
  # the configuration is applied.
  disko.zfs.enable = true;

  disko.devices =
    {
      disk = builtins.listToAttrs [
        (mkBootDisk {
          name = "nvme0";
          id = "nvme-SAMSUNG_MZVL2512HCJQ-00BH7_S640NX0Y706128";
          esp = "/boot";
        })
        (mkBootDisk {
          name = "nvme1";
          id = "nvme-SAMSUNG_MZVL2512HCJQ-00BH7_S640NX0Y713948";
          esp = "/boot2";
        })
      ];
      zpool =
        {
          ${rpool} = {
            type = "zpool";
            mode = "mirror";
            rootFsOptions = {
              # https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS
              acltype = "posixacl";
              atime = "off";
              compression = "on";
              mountpoint = "none";
              xattr = "sa";
            };
            # Dataset layout based on https://grahamc.com/blog/nixos-on-zfs/
            #
            # Which of these datasets are snapshotted is decided by the zrepl
            # snapshot job's `filesystems` filter (`services.zrepl` in
            # configuration.nix), not by dataset properties.
            datasets = {
              ${cryptDataset} = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  dnodesize = "auto";
                  encryption = "aes-256-gcm";
                  keyformat = "passphrase";
                  # The key is supplied unattended by clevis from the TPM at
                  # boot (see `boot.initrd.clevis` in configuration.nix). The
                  # `prompt` is the fallback used on the BMC console if the TPM
                  # ever refuses to release the key.
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
              };
              "${localDataset}/tmp" = {
                type = zfs_fs;
                mountpoint = "/tmp";
              };
              "${localDataset}/cache" = {
                type = zfs_fs;
                mountpoint = "/home/eliza/.cache";
              };
              "${localDataset}/root-cache" = {
                type = zfs_fs;
                mountpoint = "/root/.cache";
              };
              "${localDataset}/reserved" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  canmount = "off";
                  refreservation = "50G";
                };
              };
              "${systemDataset}" = {
                type = zfs_fs;
                options.mountpoint = "none";
              };
              "${systemDataset}/root" = {
                type = zfs_fs;
                mountpoint = "/";
                # Ensure that /tmp and /root/.cache are rw; for some reason,
                # these sometimes get mounted ro by initrd?
                mountOptions = [ "rw" ];
                options = {
                  dnodesize = "auto";
                };
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${rpool}/${systemDataset}/root@blank$' || zfs snapshot ${rpool}/${systemDataset}/root@blank";
              };
              "${systemDataset}/var" = {
                type = zfs_fs;
                mountpoint = "/var";
                options = {
                  dnodesize = "auto";
                };
              };
              "${systemDataset}/etc" = {
                type = zfs_fs;
                mountpoint = "/etc";
                options = {
                  dnodesize = "auto";
                };
              };
              "${userDataset}" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  dnodesize = "auto";
                };
              };
              "${userDataset}/home" = {
                type = zfs_fs;
                mountpoint = "/home";
              };
            };
          };
        };
    };
}
