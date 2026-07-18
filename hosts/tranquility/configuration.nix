{ config, pkgs, lib, ... }:

with pkgs; with lib; {

  imports = [ ./hardware-configuration.nix ./disko-config.nix ];

  # agenix-rekey host identity (sealed in the TPM using
  # `profiles.age.tpmHostIdentity`)
  age.rekey.hostPubkey = "age1tpm1qd2z32tv4z7nz47hjnalx2e5z3yu7rgc8ltqjusnlaka4hcz0jaqcr9hqvy";

  profiles = {
    age.tpmHostIdentity.enable = true;
    server.enable = true;
    desktop = {
      gnome3.enable = true;
    };
    observability = {
      enable = true;
      snmp.enable = true;
    };

    zfs.enable = true;
  };

  age.secrets.hakofoundry-secret = {
    generator.script = "base64";
  };
  # Generate a file in the .env format
  age.secrets.hakofoundry-env = {
    generator = {
      dependencies = {
        inherit (config.age.secrets) hakofoundry-secret;
      };
      script = { pkgs, lib, decrypt, deps, ... }: ''
        printf 'SECRET="%s"\n' $(${decrypt} ${lib.escapeShellArg deps.hakofoundry-secret.file})
      '';
    };
  };

  services.hakoFoundry = {
    enable = true;
    secretFilePath = config.age.secrets.hakofoundry-env.path;
    openFirewall = true;
  };

  environment.systemPackages = with pkgs; [
    sbctl
    fwupd
    # various LSI SAS card thingies
    storcli2
    lsirec
    lsiutil
    lsscsi
    # seagate drive firmware utility
    openseachest
    sg3_utils
  ];

  # fwupd: firmware update
  services.fwupd.enable = true;

  #### System configuration ####
  networking = {
    # machine's hostname
    hostName = "tranquility";
    # this has to be a unique 32-bit number. ZFS requires us to define this.
    hostId = "00C0FFEE";

    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = false;
  };

  #### Boot configuration ####
  boot = {
    loader = {

      # Lanzaboote currently replaces the systemd-boot module.
      # This setting is usually set to true in configuration.nix
      # generated at installation time. So we force it to false
      # for now.
      systemd-boot.enable = mkForce false;
      efi = {
        canTouchEfiVariables = true;
        # Primary ESP at the standard `/boot` mountpoint so `sbctl`/`bootctl`
        # can find it (they only probe `/efi`, `/boot`, `/boot/efi` by default).
        # The second disk's ESP is added via
        # `boot.lanzaboote.extraEfiSysMountPoints` below.
        efiSysMountPoint = "/boot";
      };
    };

    # Secure Boot via lanzaboote. lzbt signs the UKI and installs the
    # bootloader to *every* ESP listed, so the system boots (and verifies)
    # from either NVMe device. This requires the systemd-based initrd.
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 8;
      extraEfiSysMountPoints = [ "/boot2" ];
      # Automatically provision the Secure Boot keys on first boot.
      autoGenerateKeys.enable = true;
      autoEnrollKeys = {
        enable = true;
        # Microsoft keys are included to ensure signed option ROMs (such as the
        # LSI SAS HBAs in this box) are not locked out.
        includeMicrosoftKeys = true;
      };
    };

    initrd.supportedFilesystems = [ "zfs" ];
    # systemd-based initrd is required for clevis TPM unlocking and for
    # lanzaboote's extraEfiSysMountPoints.
    initrd.systemd = {
      enable = true;
      # Allow a root rescue shell in the initrd emergency target. Without this,
      # a failed pool import (or any stage-1 failure) drops to emergency mode
      # with root locked, which strands a headless box. This is reachable only
      # *before* the pool is unlocked, so it exposes no decrypted data. It's
      # just for debugging, and manually unlocking the pool if necessary.
      emergencyAccess = true;
    };
    # Unattended unlock of the root pool's encryption root from the TPM via
    # clevis. The JWE seals the ZFS passphrase against *this machine's* TPM
    # (empty policy, no PCR binding), so it survives kernel/firmware updates and
    # is only decryptable on this host, which makes it safe to commit. If the
    # TPM ever refuses, ZFS falls back to prompting for the passphrase, so that
    # the root FS can still be unlocked manually.
    #
    # The JWE is generated on the running system after first boot (see README);
    # it only needs root TPM access, not Secure Boot enrollment. Until it has
    # been committed, clevis is disabled and the pool is unlocked by entering
    # the passphrase at the prompt. This keeps the configuration evaluable
    # before the secret exists, which is necessary for installation.
    initrd.clevis = lib.mkIf (builtins.pathExists ./tranquility-rpool-crypt.jwe) {
      enable = true;
      devices."tranquility-rpool/crypt".secretFile = ./tranquility-rpool-crypt.jwe;
    };
    # Request ZFS encryption credentials for the root pool's encryption root at
    # boot (satisfied unattended by clevis, above).
    zfs.requestEncryptionCredentials = [ "tranquility-rpool/crypt" ];
    # Force-import the root pool at boot (`zpool import -f`). This is fine to do
    # for the root zpool, as it is not shared over the network.
    zfs.forceImportRoot = true;

    kernelModules = [ "bnxt_en" "e1000e" "alx" "r8169" "igb" "cdc_ether" "r8152" ];
  };
  # enable ssh early
  systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
  # # start ttyS0 early so that IPMI SoL works
  # systemd.services."serial-getty@ttyS0".wantedBy = [ "multi-user.target" ];

  # TPM 2.0-backed SSH hostkeys using ssh-tpm-agent.
  services.ssh-tpm-hostkeys.enable = true;
  services.openssh.enable = true;

  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │
    └┴────────────────┘
    ${config.networking.hostName}: storage
  '';

  # Per-encryption-root passphrases for the `moonpool` data pool. These are
  # generated (six random words), stored encrypted to the agenix master identity
  # in `secrets/generated/`, and rekeyed for this host's TPM-sealed identity
  # into `secrets/rekeyed/tranquility/`. They are delivered to `/run/agenix/...`
  # at boot and read by the `zfs-datasets-moonpool` oneshot to unlock the
  # datasets unattended.
  #
  # `keyformat=passphrase` also means any of these can be unlocked by hand on
  # any machine with `zfs load-key -L prompt <dataset>`. For that offline /
  # foreign-machine recovery path to need nothing but a password manager, copy
  # each generated passphrase into 1Password once (read it with `agenix view`);
  # otherwise recovery also needs this flake + the master identity.
  age.secrets.moonpool-system-pass.generator.script = "passphrase";
  age.secrets.moonpool-user-eliza-pass.generator.script = "passphrase";

  # moonpool dataset layout (see hosts/tranquility/README.md). The
  # `profiles.zfs.pools` wrapper (modules/nixos/profiles/zfs/datasets.nix)
  # routes unencrypted datasets through the early disko-zfs service and the
  # encrypted subtrees through a late per-pool oneshot (their passphrases are
  # agenix secrets, unavailable when the early service runs). The pool itself is
  # created and grown statefully (drives fail and get replaced); only the dataset
  # layout is declarative.
  profiles.zfs.pools.moonpool = {
    # Pool-root properties. All creation-time local properties are declared so
    # disko-zfs does not inherit (unset) them during reconciliation.
    properties = {
      mountpoint = "none";
      compression = "lz4";
      atime = false;
      # `acltype=posixacl` and `xattr=sa are needed for NFS/Samba
      acltype = "posixacl";
      xattr = "sa";
      dnodesize = "auto";
      recordsize = "128K";
      autoSnapshot = false;
      # Disable the `frequent` label pool-wide by default to disable 15-minute snapshot
      # intervals.
      autoSnapshotFrequent = false;
    };

    datasets = {
      # Container for this generation of the dataset layout.
      "ds1".properties = {
        mountpoint = "none";
        autoSnapshot = false;
      };

      # Bulk media: unencrypted (re-downloadable, non-sensitive) and not
      # auto-snapshotted. Large records: fewer indirect blocks (which also
      # relieves the special vdev) and better sequential throughput; media
      # files are never partially rewritten, so there is no RMW downside.
      "ds1/media".properties = {
        mountpoint = "/srv/media";
        recordsize = "1M";
        autoSnapshot = false;
      };

      # Encrypted state for data-serving services. Child datasets (added later,
      # per service, mounted into /var/lib/<service>) inherit this key.
      "ds1/system" = {
        encryption = {
          keyFile = config.age.secrets.moonpool-system-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
          autoSnapshot = true;
        };
      };

      # Unencrypted container under which each user gets their own encryption
      # root (own key). Add more users by adding another encrypted child here.
      "ds1/users".properties = {
        mountpoint = "none";
        autoSnapshot = false;
      };

      "ds1/users/eliza" = {
        encryption = {
          keyFile = config.age.secrets.moonpool-user-eliza-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
          autoSnapshot = true;
          # TODO: set `quota` here to cap this user's total usage. It must be
          # declared *here*: a hand-run `zfs set quota=...` is local property
          # drift, which reconciliation reverts on the next service run.
        };
      };

      # Fileshares hold a mixed corpus whose largest category is
      # multi-megabyte PDFs (~1.2--35MB), plus assorted smaller files.
      # `recordsize=1M` suits the big files (whole-file sequential I/O, 8x
      # fewer indirect blocks than the 128K default); files smaller than the
      # recordsize are stored as a single block of roughly the file's size,
      # so the cap costs them nothing. `special_small_blocks=512K` routes
      # those small blocks (files up to ~512K) to the special vdev's SSDs,
      # where per-file seek latency hurts most; the 1M PDF chunks stay on the
      # HDDs. Do NOT raise the threshold to the recordsize --- that routes
      # *all* data to the special vdev. Metadata is protected from this data
      # by the built-in class gate (`zfs_special_class_metadata_reserve_pct`,
      # default 25%); watch the fill with `zpool list -v moonpool`.
      "ds1/users/eliza/shares" = {
        # Applied once, at dataset creation; never reconciled afterwards.
        owner = "eliza";
        group = "users";
        mode = "0700";
        properties = {
          mountpoint = "/srv/users/eliza/shares";
          recordsize = "1M";
          specialSmallBlocks = "512K";
          autoSnapshot = true;
        };
      };

      # Backups are large sequential blobs; large records, same as media.
      # Never set `special_small_blocks` here: chunk-based backup tools
      # (borg/restic) write exactly midsize blocks and would soak terabytes
      # of backup data into the special vdev.
      "ds1/users/eliza/backups" = {
        owner = "eliza";
        group = "users";
        mode = "0700";
        properties = {
          mountpoint = "/srv/users/eliza/backups";
          recordsize = "1M";
          autoSnapshot = true;
        };
      };
    };
  };

  # This option defines the first version of NixOS you have installed on this
  # particular machine, and is used to maintain compatibility with application
  # data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any
  # reason, even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are
  # pulled from, so changing it will NOT upgrade your system - see
  # https://nixos.org/manual/nixos/stable/#sec-upgrading for how to actually do
  # that.
  #
  # This value being lower than the current NixOS release does NOT mean your
  # system is out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes
  # it would make to your configuration, and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or
  # https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?
}
