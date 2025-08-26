let
  rpool = "hekate-rpool";
  userDataset = "user";
  cryptDataset = "${userDataset}/crypt";
  homeDataset = "${cryptDataset}/home";
  zfs_fs = "zfs_fs";
  sn840ids = [ "A079DDAA" "A079E3F9" "A079E4D6" "A084A645" ];
  mkSn840 = (id: {
    name = "sn840-${id}";
    value = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-WUS4C6432DSP3X3_${id}";
      content = {
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
    };
  }
  );
in
{
  disko.devices =
    {
      disk =
        let
          sn840s = builtins.listToAttrs (map mkSn840 sn840ids);
        in
        {
          boot = {
            type = "disk";
            device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S3PZNF0JA28518H";
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
              };
            };
          };
        } // sn840s;
      zpool =
        let
          localDataset = "local";
          systemDataset = "system";
          optAutosnapshot = "com.sun:auto-snapshot";
          optSystemd = "org.openzfs.systemd";
          # default options for encrypted datasets
          optsCrypt =
            {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              keylocation = "prompt";
            };
        in
        {
          ${rpool} = {
            type = "zpool";
            rootFsOptions = {
              # Using "compression = on" instead of explicitly specifiying
              # compression allows ZFS to pick the best one.
              compression = "on";
              # Nix doesn’t use atime, so atime=off on the /nix dataset is fine.
              atime = "off";
              mountpoint = "none";
            };
            mode = {
              topology = {
                type = "topology";
                vdev = [
                  {
                    mode = "raidz2";
                    members = map (id: "sn840-${id}") sn840ids;
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
                  ${optAutosnapshot} = "false";
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
                  ${optAutosnapshot} = "true";
                };
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${rpool}/${systemDataset}/root@blank$' || zfs snapshot ${rpool}/${systemDataset}/root@blank";
              };
              "${systemDataset}/var" = {
                type = zfs_fs;
                mountpoint = "/var";
                options = {
                  # The dataset containing journald’s logs (where /var lives) should
                  # have xattr = sa and acltype=posixacl set to allow regular users
                  # to read their journal.
                  acltype = "posixacl";
                  xattr = "sa";
                  # Disable autosnapshot for `/var`.
                  ${optAutosnapshot} = "false";
                };
              };
              "${systemDataset}/etc" = {
                type = zfs_fs;
                mountpoint = "/etc";
                options = {
                  # The dataset containing journald’s logs (where /var lives) should
                  # have xattr = sa and acltype=posixacl set to allow regular users
                  # to read their journal.
                  acltype = "posixacl";
                  xattr = "sa";
                  # Disable autosnapshot for `/etc` --- this should all come
                  # from the nix store!
                  ${optAutosnapshot} = "false";
                };
              };
              "${userDataset}" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  # Snapshot all user datasets.
                  ${optAutosnapshot} = "true";
                };
              };
              "${cryptDataset}" = {
                type = zfs_fs;
                options = {
                  mountpoint = "none";
                  # Snapshot all user datasets.
                  ${optAutosnapshot} = "true";
                  # Systemd should not mount encrypted datasets on boot.
                  "${optSystemd}:ignore" = "on";
                } // optsCrypt; # enable encryption
              };
              "${homeDataset}" = {
                type = zfs_fs;
                mountpoint = "/home";
              };
              "${homeDataset}/eliza" = {
                type = zfs_fs;
                mountpoint = "/home/eliza";
              };
            };
          };
        };
    };

  # Unlock user datasets on user login, rather than on boot..
  security.pam.zfs = {
    enable = true;
    homes = "${rpool}/${homeDataset}";
  };

}
