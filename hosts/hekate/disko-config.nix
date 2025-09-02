let
  rpool = "hekate-rpool";
  userDataset = "user";
  homeDataset = "${userDataset}/home";
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
                  label = "EFI";
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
              acltype = "posixacl";
              xattr = "sa";
              mountpoint = "none";
            };
            options = {
              ashift = "12";
              autotrim = "on";
            };
            mode = {
              topology = {
                type = "topology";
                vdev = [
                  {
                    mode = "mirror";
                    members = [
                      "sn840-A079DDAA"
                      "sn840-A079E3F9"
                    ];
                  }
                  {
                    mode = "mirror";
                    members = [
                      "sn840-A079E4D6"
                      "sn840-A084A645"
                    ];
                  }
                ];
              };
            };
            # Dataset layout based on https://grahamc.com/blog/nixos-on-zfs/
            datasets = {
              ${localDataset} = {
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
              ${systemDataset} = {
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
                  # Systemd should not mount encrypted datasets on boot.
                  canmount = "off";
                  "${optSystemd}:ignore" = "on";
                  mountpoint = "none";
                  dnodesize = "auto";
                  # Snapshot all user datasets.
                  ${optAutosnapshot} = "true";
                };
              };
              "${homeDataset}" = {
                type = zfs_fs;
                options = {
                  "${optSystemd}:ignore" = "on";
                  # EXTREMELY IMPORTANT: This must be `options.mountpoint`,
                  # rather than `mountpoint`! The `options.mountpoint` key ONLY
                  # sets the ZFS mountpoint option, while `mountpoint` also
                  # tells Disko to generate systemd mount units for the dataset
                  # that will try to mount it on boot. Since we want it to be
                  # mounted by PAM on login, we must set the mountpoint for ZFS
                  # but we must *not* generate any other systemd mount
                  # configuration.
                  mountpoint = "/home";
                  canmount = "noauto";
                };
              };
              "${homeDataset}/eliza" = {
                type = zfs_fs;
                options = {
                  # EXTREMELY IMPORTANT: This must be `options.mountpoint`,
                  # rather than `mountpoint`! The `options.mountpoint` key ONLY
                  # sets the ZFS mountpoint option, while `mountpoint` also
                  # tells Disko to generate systemd mount units for the dataset
                  # that will try to mount it on boot. Since we want it to be
                  # mounted by PAM on login, we must set the mountpoint for ZFS
                  # but we must *not* generate any other systemd mount
                  # configuration.
                  mountpoint = "/home/eliza";
                  "${optSystemd}:ignore" = "on";
                  canmount = "on";
                } // optsCrypt;
              };
            };
          };
        };
    };

  # Unlock user datasets on user login, rather than on boot..
  security.pam = {
    # mount.enable = true;
    zfs = {
      enable = true;
      homes = "${rpool}/${homeDataset}";
    };
  };

  # Ensure that sshd always asks for a password.
  services.openssh.settings = {
    PubkeyAuthentication = true;
    PasswordAuthentication = true;

    # Always authenticate using the public key, but additionally, ask for the
    # password, so that the password is available to PAM to unlock encrypted ZFS
    # datasets.
    AuthenticationMethods = "password,publickey";
  };
}
