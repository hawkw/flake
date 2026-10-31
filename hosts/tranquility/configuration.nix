{ config, pkgs, lib, ... }:

with pkgs; with lib; {

  imports = [ ./hardware-configuration.nix ./disko-config.nix ];

  # agenix-rekey host identity (sealed in the TPM using
  # `profiles.age.tpmHostIdentity`)
  age.rekey.hostPubkey = "age1tpm1qd2z32tv4z7nz47hjnalx2e5z3yu7rgc8ltqjusnlaka4hcz0jaqcr9hqvy";

  profiles = {
    age.tpmHostIdentity.enable = true;
    hardened = {
      enable = true;
      kernel.enable = true;
      systemd.enable = true;
    };
    server.enable = true;
    storage.enable = true;
    desktop = {
      gnome3.enable = true;
    };
    observability = {
      enable = true;
      snmp.enable = true;
    };

    yubikey.ssh.enable = true;
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
      # with root locked, which strands a headless box. It's just for
      # debugging, and for manually unlocking the pool if necessary.
      #
      # This shell is reached before the pool is unlocked, so it doesn't expose
      # any decrypted data. However, it does have the same TPM access as the
      # clevis unlock, so it could `clevis decrypt` the initrd's JWE itself.
      # This is still the case after binding the JWE to PCR 7 (see README),
      # because the initrd sees the same Secure Boot state. Therefore, anyone
      # at the console who can cause a stage-1 failure could recover the
      # passphrase.
      #
      # TODO(eliza): before relying on the PCR 7 binding, set this to a hashed
      # root password instead of `true` (the option accepts one). Note that the
      # hash is stored in the unencrypted initrd, so the password must be strong
      # enough to resist offline cracking.
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

  # `/etc` is its own ZFS dataset (see disko-config.nix), and
  # `switch-to-configuration` restarts (unmounts + remounts) a changed
  # `etc.mount` rather than reloading it in place as it does for `/` and `/nix`.
  # This can blip the `/etc` filesystem in and out of existence for a moment,
  # causing systemd services which read/write files that should exist in `/etc`
  # to transiently fail when the configuration is reloaded. Therefore, bind them
  # to requiring the mount for `/etc` so that they don't restart until it has
  # been re-mounted.
  #
  # TODO(eliza): i should probably get around to opening an upstream issue for
  # actually fixing this...
  systemd.services.systemd-tpm2-setup.unitConfig.RequiresMountsFor = "/etc";
  systemd.services.accounts-daemon.unitConfig.RequiresMountsFor = "/etc";

  # TPM 2.0-backed SSH hostkeys using ssh-tpm-agent.
  services.ssh-tpm-hostkeys.enable = true;
  services.openssh.enable = true;

  # Convenience symlink so SFTP-relative paths resolve from $HOME:
  # `scp f tranquility:shares/`, `sftp`'s `cd shares`, and
  # `sshfs eliza@tranquility:shares mnt/` (the last needs
  # `-o follow_symlinks`, or spell the absolute /srv path). SFTP resolves
  # paths server-side, so the symlink is traversed like any directory; it
  # also keeps GNOME/tracker and $HOME-scoped tools off the share (they do
  # not follow symlinks), unlike a real mountpoint in the homedir would.
  # `L` (not `L+`): never clobbers an existing ~/shares.
  systemd.tmpfiles.rules = [
    "L /home/eliza/shares - - - - /srv/users/eliza/shares"
  ];

  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │
    └┴────────────────┘
    ${config.networking.hostName}: storage
  '';

  # Per-encryption-root passphrases for the `moonpool` data pool. These are
  # generated using an agenix random-word generator, stored encrypted to the
  # agenix master identity in `secrets/generated/`, and rekeyed for this host's
  # TPM-sealed identity into `secrets/rekeyed/tranquility/`. These keys are read
  # by the `zfs-datasets-moonpool` oneshot to unlock the datasets unattended.
  #
  # `keyformat=passphrase` also means any of these can be unlocked by hand on
  # any machine with `zfs load-key -L prompt <dataset>`. The passphrases can
  # also be escrowed into an external password manager using `agenix view`.
  age.secrets.moonpool-service-pass.generator.script = "passphrase";
  age.secrets.moonpool-user-eliza-pass.generator.script = "passphrase";

  # The main storage pool for this system.
  #
  # The zpool itself is created and managed statefully (using the ZFS CLI)`,
  # while the datasets on it are declared here and managed by the `datasets.nix`
  # module in this flake.
  profiles.zfs.pools.moonpool = {
    # Pool-root properties applied to all datasets by default.
    properties = {
      mountpoint = "none";
      compression = "lz4";
      atime = false;
      # `acltype=posixacl` and `xattr=sa` are needed for NFS/Samba
      acltype = "posixacl";
      xattr = "sa";
      dnodesize = "auto";
      recordsize = "128K";
      autoSnapshot = false;
      # Disable the `frequent` label pool-wide by default to disable 15-minute
      # snapshot intervals.
      autoSnapshotFrequent = false;
    };

    datasets = {
      # Reservation to ensure the pool is never completely full.
      "reserved".properties = {
        mountpoint = "none";
        autoSnapshot = false;
        reservation = "16G";
      };

      # Container for this generation of the dataset layout.
      "ds1".properties = {
        mountpoint = "none";
        autoSnapshot = false;
      };

      # Media (movies, etc) that can be re-downloaded if lost.
      "ds1/media".properties = {
        mountpoint = "/srv/media";
        # Use large blocks for movies etc. They are never partially rewritten,
        # so there should be no RMW drawback to large recordsize.
        recordsize = "1M";
        # No need to snapshot anything that can be downloaded again and which
        # and doesn't change once written.
        autoSnapshot = false;
      };

      # Encrypted container dataset for services hosted by this system. These
      # will generally be mounted into /srv, with child datasets for various
      # services.
      "ds1/services" = {
        encryption = {
          keyFile = config.age.secrets.moonpool-service-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
          autoSnapshot = true;
        };
      };

      # Container for per-user encrypted datasets.
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
          # TODO: set a `quota` here...
        };
      };

      # Fileshares for the eliza user
      "ds1/users/eliza/export" = {
        # Applied at dataset creation.
        owner = "eliza";
        group = "users";
        mode = "0700";
        properties = {
          mountpoint = "/srv/eliza/export";
          recordsize = "1M";
          specialSmallBlocks = "512K";
          # enable zstd rather than lz4 for better compression ratios.
          compression = "zstd";
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
