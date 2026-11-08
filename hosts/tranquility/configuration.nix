{ config, pkgs, lib, ... }:

let
  # Names of ZFS storage pools and datasets.
  moonpool = "moonpool";
  datasetNames = rec {
    services = "services";
    immich = "${services}/immich";
    immichThumbs = "${immich}/thumbs";
    users = "users";
    eliza = "${users}/eliza";
    backups = "backups";
  };
in
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
  age.secrets.moonpool-backups-pass.generator.script = "passphrase";

  # The main storage pool for this system.
  #
  # The zpool itself is created and managed statefully (using the ZFS CLI)`,
  # while the datasets on it are declared here and managed by the `datasets.nix`
  # module in this flake.
  profiles.zfs.pools.${moonpool} = {
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
      # For security hardening: this pool will never store setuid binaries or
      # device nodes. Most datasets additionally do not store executables and
      # can also set `exec - "off"`, but this is configured on a per-dataset
      # basis. Some service state dirs may need executables for plugins.
      setuid = "off";
      devices = "off";
    };

    datasets = {
      # Fill margin for the whole pool. This ensures that all other datasets see
      # the pool as "full" while about 15% of the data vdev capacity remains.
      # ZFS performance tends to degrade over 80% capacity due to fragmentation
      # (see https://docs.oracle.com/cd/E26505_01/html/E37384/zfspools-4.html).
      #
      # This is not needed to guarantee that deletes can succeed on a full
      # pool, since ZFS's own slop space already does that.
      #
      # This is sized for one 6-wide raidz2 vdev of 16 TB disks (~58 TiB
      # usable). It does not scale automatically, so it will need to be
      # increased when adding new data vdevs.
      #
      # In an emergency, the reservation can be released with
      # `zfs set reservation=none moonpool/reserved`.
      "reserved".properties = {
        mountpoint = "none";
        reservation = "8T";
      };

      # Media (movies, etc) that can be re-downloaded if lost
      #
      # These are never snapshotted, since anything here can be downloaded again
      # and doesn't change once written. This tree does not need to be
      # encyrpted.
      "media".properties = {
        mountpoint = "none";
        # Don't let a large download queue fill up the whole pool.
        # NOTE: consider expanding this when adding new data vdevs.
        quota = "30T";
        exec = "off";
        # Don't keep a ditto copy of files' level-1 indirect blocks, which are
        # the bulk of metadata by volume and all live on the special vdev. This
        # halves the metadata write churn from torrents' out-of-order writes to
        # `media/incomplete` (the largest source of special-vdev writes), and
        # trims the special-vdev footprint of the library slightly.
        #
        # The cost: if all three mirror copies of one L1 block are corrupt, up
        # to ~1024 records of a single file are lost (16 MB of an incomplete
        # download, or 1 GiB of a library file), rather than one record.
        # The loss is detected and reported by name, and this data can be
        # re-downloaded. Do not inherit this into irreplaceable data.
        redundant_metadata = "most";
      };

      # The media library *and* completed downloads that are still seeding.
      # These must be one dataset: the *arr stack hardlinks completed downloads
      # into the library, and hardlinks cannot cross datasets.
      "media/complete".properties = {
        mountpoint = "/srv/media";
        # Use large blocks for movies etc. They are never partially rewritten,
        # so there should be no RMW drawback to large recordsize.
        recordsize = "1M";
      };

      # In-progress torrent downloads. Torrent clients write pieces out of
      # order, which would fragment 1M records; the client moves completed
      # downloads into `media/complete`, which (crossing datasets) rewrites
      # them as 1M records. Mounted outside /srv/media so that everything
      # under /srv/media remains one filesystem.
      "media/incomplete".properties = {
        mountpoint = "/srv/media-incomplete";
        # Matches libtorrent's 16K block size, and is the smallest size at
        # which raidz2 parity overhead reaches the ideal 1.5x.
        recordsize = "16K";
        # Explicitly override the special small blocks setting here in case we
        # change the parent default in the future. I really don't want temporary
        # download files that are about to be copied elsewhere to ever spend
        # flash capacity/write endurance.
        specialSmallBlocks = 0;
        # A crash mid-download causes a torrent recheck; piece hashes catch any
        # torn writes.
        sync = "disabled";
      };

      # Encrypted container dataset for services hosted by this system.
      # Per-service datasets are mounted at the services' default state
      # directories (mostly under /var/lib), and ownership over these
      # mountpoints are mostly configured by the service's NixOS modules (i.e.
      # using systemd `StateDirectory=`). Non-default paths must be created by
      # hand.
      #
      # This subtree is snapshotted by zrepl.
      ${datasetNames.services} = {
        encryption = {
          keyFile = config.age.secrets.moonpool-service-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
        };
      };

      # PostgreSQL's data directory (`/var/lib/postgresql/<schema>`), configured
      # by the system-wide `services.postgresql` (if it is enabled).
      #
      # This is the single PostgreSQL instance shared by Immich and by nixflix
      # (`nixflix.postgres.enable`, which uses the system
      # `services.postgresql`.
      #
      # NOTE: when configuring nixflix, override its `log.dbEnabled = true` with
      # `nixflix.<service>.settings.log.dbEnabled = lib.mkForce false` for each
      # *arr service, so that they log to files instead. Otherwise, their
      # application logs are constantly inserted into and trimmed from a
      # database here, which would result in a great deal of additional flash
      # writes that are probably not necessary. (nixflix will still create the
      # empty `<service>-logs` databases, but this is t harmless.)
      "${datasetNames.services}/postgresql" = lib.mkIf config.services.postgresql.enable {
        properties = {
          mountpoint = "/var/lib/postgresql";
          # NOTE: this must stay at or above PostgreSQL's 8K page size, because
          # `full_page_writes = false` (see `services.postgresql.settings`)
          # relies on ZFS writing each page as part of a single record.
          recordsize = "16K";
          specialSmallBlocks = "16K";
          # Set a quota for the postgres dataset since it lands entirely on the
          # special vdev. This way, if the database grows past its quota, it
          # fails with ENOSPC rather than silently pushing other stuff off the
          # special vdev.
          #
          # Since exceeding this quota would take down all services sharing this
          # postgres instance, it's sized pretty generously:
          #
          # - Immich at ~450k assets: ~5-15 GB.
          # - The *arr databases: ~1-15 GB, dominated by Lidarr's MusicBrainz
          #   metadata if music is managed.
          # - Snapshot-retained churn on top of that: the monthly snapshots
          #   keep up to two months of rewritten pages.
          #
          # Raise it if more databases move here, and keep the special vdev's
          # total budget in mind when doing so.
          quota = "100G";
          # Postgres pages compress well, and this data lives on flash, so a
          # better ratio saves both special-vdev capacity and write volume.
          compression = "zstd";
          # PostgreSQL's binaries and extensions come from the Nix store, and
          # its JIT compiles in memory, so nothing in the data directory is
          # ever executed.
          exec = "off";
        };
      };

      # Immich's media storage, including originals, uploads, transcoded videos,
      # and Immich's own nightly database dumps. These stay on the HDDs. Uploads
      # land in `upload/` and are moved into `library/`. Both of those
      # directories should be on the same dataset, in to ensure that moving
      # from uploads to library is a rename rather than a copy.
      ${datasetNames.immich} = lib.mkIf config.services.immich.enable {
        properties = {
          mountpoint = config.services.immich.mediaLocation;
          recordsize = "1M";
          # Immich's binaries (and ffmpeg, libvips) come from the Nix store, and
          # its ML model cache is in /var/cache, so nothing here is ever
          # executed. Inherited by `thumbs`. This is set per dataset rather
          # than on `services`, since other services' state directories may
          # need exec (see the pool-root properties).
          exec = "off";
        };
      };

      # Immich's generated images include grid thumbnails (~10-30 KB WebP),
      # previews (~200-500 KB JPEG), and face crops.
      #
      # These can all be regenerated from the library, so they are never
      # snapshotted, and we store less redundant metadata.
      #
      # Only the small files go on the special vdev. Grid thumbnails are read
      # dozens to hundreds at a time from all over the library (timeline,
      # search, people, map), so they benefit from flash pretty substantially.
      # This also helps keep browsing the library responsive the HDDs are busy
      # (i.e. due to a scrub or periodic backup jobs). On the other hand,
      # previews are opened one at a time, so HDD seek latency isn't noticeable.
      # Previews will be large enough to write full 128K full records.
      # Therefore, they exceed the 64K special small blcoks threshold and are
      # stored on go on the HDDs, as would any multi-MB images from Immich's
      # "full-size image" generation (`image.fullsize.enabled`). This puts
      # ~15-20 GB on the special vdev at ~450k assets, rather than everything.
      #
      # If changing any settings on this dataset that only effect newly-written
      # files, run Immich's "regenerate all thumbnails" job.
      #
      # Immich refuses to start if this dataset is not mounted.
      ${datasetNames.immichThumbs} = lib.mkIf config.services.immich.enable {
        # Applied at dataset creation. The mount root must be writable by
        # Immich, and the user only exists while Immich is enabled.
        owner = config.services.immich.user;
        group = config.services.immich.group;
        mode = "0700";
        properties = {
          mountpoint = "${config.services.immich.mediaLocation}/thumbs";
          recordsize = "128K";
          specialSmallBlocks = "64K";
          quota = "250G";
          # Thumbnails and previews can always be regenerated from the library,
          # sothe same reasoning as on `media` applies. The saving here is small
          # (~2 GB of flash at ~450k assets), since only previews are large
          # enough to have L1 indirect blocks at all. The risk of enabling this
          # is that a corrupt L1 loses one preview, is fine because they can
          # always be recreated by Immich's "generate missing thumbnails" job.
          redundant_metadata = "most";
        };
      };

      # Container for per-user encrypted datasets. This subtree is snapshotted
      # by zrepl (see `services.zrepl`).
      ${datasetNames.users}.properties = {
        mountpoint = "none";
      };

      "users/eliza" = {
        encryption = {
          keyFile = config.age.secrets.moonpool-user-eliza-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
          # Includes snapshots: edits and deletes in `shares` are retained for
          # up to two months, so this leaves headroom over ~2-3T of live data.
          quota = "4T";
        };
      };

      # Fileshares for the eliza user
      "users/eliza/shares" = {
        # Applied at dataset creation.
        owner = "eliza";
        group = "users";
        mode = "0700";
        properties = {
          mountpoint = "/srv/users/eliza/shares";
          recordsize = "1M";
          # Files up to 64K (plus all metadata) live on the special vdev.
          # The threshold applies to blocks *after* compression, so a larger
          # value would also pull every 1M record that compresses well (text,
          # source trees, tarballs) onto flash, competing with the services
          # datasets and backups for the special class's small-block
          # budget.
          specialSmallBlocks = "64K";
          # enable zstd rather than lz4 for better compression ratios.
          compression = "zstd";
          # Make `.zfs/snapshot/` visible in the dataset root. This way, files
          # can be restored from snapshots over SFTP without root.
          snapdir = "visible";
          # Only affects executing files on this host. NFS/SFTP clients that
          # copy or mount files executable from here are unaffected.
          exec = "off";
        };
      };

      # Backups of other systems, from any mechanism. Children are named after
      # the mechanism that owns them (e.g. `backups/zrepl`, and in future
      # `backups/restic`), because different mechanisms need opposite rules:
      # ZFS replicas must never be snapshotted or written to locally, while
      # file-level backup targets must be mounted and should be snapshotted.
      #
      # This is an encryption root with a server-held key as a fallback. A raw
      # (`zfs send -w`) stream always becomes its own encryption root, whose key
      # the server never holds. A non-raw stream inherits this root's
      # encryption, so a client that forgets to send raw is still encrypted at
      # rest rather than stored in plaintext.
      ${datasetNames.backups} = {
        encryption = {
          keyFile = config.age.secrets.moonpool-backups-pass.path;
          keyFormat = "passphrase";
        };
        properties = {
          mountpoint = "none";
          # Only affects streams that arrive uncompressed (non-raw, without
          # `zfs send -c`). Raw and compressed streams are written as received,
          # keeping the source's compression.
          compression = "zstd";
          exec = "off";
        };
      };

      # zrepl sink `root_fs`. Everything below this dataset is owned by zrepl,
      # which creates a child per client identity.
      #
      # This subtree must never be matched by the local snapshot job (see
      # `services.zrepl`): a local snapshot newer than the last received one
      # breaks the next incremental receive.
      "${datasetNames.backups}/zrepl".properties = {
        mountpoint = "none";
      };
    };
  };

  # immich-server has no dependency on its media location's mount, so it could
  # start before moonpool is imported and unlocked, and write into the empty
  # mountpoint on the root filesystem. (postgresql.service already has
  # `RequiresMountsFor=` on its data directory.)
  systemd.services.immich-server = lib.mkIf config.services.immich.enable {
    requiresZfsMounts = [
      config.services.immich.mediaLocation
      "${config.services.immich.mediaLocation}/thumbs"
    ];
  };

  # PostgreSQL tuning for ZFS. These take effect only once something enables
  # PostgreSQL (e.g. Immich, which does by default); they do not enable it.
  #
  # They cut WAL volume substantially, and WAL is the largest steady writer to
  # the special vdev.
  services.postgresql.settings = {
    # Full-page writes guard against torn pages from a crash partway through
    # writing an 8K page. ZFS is copy-on-write and writes each record
    # atomically, so a page can never be torn as long as the dataset's
    # `recordsize` is at least 8K (see `services/postgresql`).
    full_page_writes = false;
    # On a copy-on-write filesystem, zero-filling new WAL segments and
    # recycling old ones buys nothing, since every write allocates new blocks
    # anyway. PostgreSQL added these options for exactly this case.
    wal_init_zero = false;
    wal_recycle = false;
  };

  # Local snapshots of both pools are taken and pruned by zrepl, rather than
  # zfs-auto-snapshot (which the zfs profile enables by default). zrepl will
  # also handle replication later; having a single tool own every snapshot
  # avoids two pruners fighting over the same datasets, and zrepl's holds on
  # snapshots it is replicating from conflicting with another tool's pruning.
  #
  # Which datasets are snapshotted is decided by the `filesystems` filter
  # below, *not* by the `com.sun:auto-snapshot` property.
  services.zfs.autoSnapshot.enable = false;
  services.zrepl = {
    enable = true;
    settings.jobs = [{
      # zrepl requires that a job's name never changes.
      name = "snapshots";
      type = "snap";
      # Patterns ending in `<` match a dataset and all of its descendants;
      # more specific patterns take precedence, and anything not matched is
      # not snapshotted.
      filesystems = {
        "${moonpool}/${datasetNames.services}<" = true;
        # Regenerable, and would only hold onto deleted images.
        "${moonpool}/${datasetNames.immichThumbs}" = false;
        "${moonpool}/${datasetNames.users}<" = true;
        # Received replicas from other systems. Their snapshots are pruned by
        # the sending side's `keep_receiver` rules, and a local snapshot would
        # break the next incremental receive. This is excluded explicitly,
        # rather than by simply not matching it, so that widening this filter
        # (e.g. to "${dataPool}<") can never pull it in: the more specific
        # pattern wins.
        "${moonpool}/${datasetNames.backups}<" = false;
        # Also not snapshotted, by not matching: `media` (re-downloadable) and
        # `reserved` (empty).

        "tranquility-rpool/crypt/system/root" = true;
        "tranquility-rpool/crypt/user<" = true;
        # Not snapshotted: `crypt/local` (/nix, /tmp, caches), and `/var` and
        # `/etc` (whose contents come from this configuration).
      };
      snapshotting = {
        type = "periodic";
        interval = "1h";
        prefix = "zrepl_";
      };
      pruning.keep = [
        # Hourly for a day, then daily for 3 days, weekly for 2 weeks, and
        # every 30 days for 2 months. This matches the retention previously
        # configured for zfs-auto-snapshot.
        {
          type = "grid";
          regex = "^zrepl_";
          grid = "24x1h | 3x1d | 2x7d | 2x30d";
        }
        # zrepl destroys any snapshot that no rule keeps. Keep every snapshot
        # zrepl did not create, such as the root dataset's `@blank`, manual
        # snapshots, and any `zfs-auto-snap_*` snapshots left over from
        # zfs-auto-snapshot (see the README for cleaning those up).
        {
          type = "regex";
          negate = true;
          regex = "^zrepl_";
        }
      ];
    }];
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
