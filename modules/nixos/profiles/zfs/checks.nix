# Checks for `profiles.zfs.pools` (./datasets.nix).
#
# These checks evaluate small, self-contained NixOS systems (not any real host),
# and make assertions about the generated configuration. They check how pools
# are classified, which units, `fileSystems` entries, and disko devices are
# generated, which dependencies are added to services that use datasets, and
# that unsupported configurations fail evaluation with the intended assertion.
# In addition, the check's build step builds one data pool's runner (so that its
# generated script is checked by `writeShellApplication`'s shellcheck), and
# inspects the properties the runner applies. None of these checks actually run
# ZFS.
#
# The module classifies pools based on their declared mountpoints, using the
# same rule that nixpkgs applies to `fileSystems` entries to decide which pools
# the initrd imports. These checks test whether nixpkgs agrees with the module
# based on how the nixpkgs ZFS module behaves: it only creates a stage-2
# `zfs-import-<pool>` service for data pools, and only creates an initrd one for
# root pools. If a nixpkgs update changes its rule, those tests will fail.
{ nixpkgs, disko, disko-zfs, pkgs }:
let
  inherit (pkgs) lib;

  # Evaluates a minimal NixOS system containing this module, disko and
  # disko-zfs (which it configures), and `extra`.
  eval = extra: (nixpkgs.lib.nixosSystem {
    modules = [
      disko.nixosModules.disko
      disko-zfs.nixosModules.default
      ./datasets.nix
      ({ lib, ... }: {
        # Stands in for the option declared by ./default.nix; importing that
        # would also pull in its kernel selection, which is slow to evaluate
        # and irrelevant here.
        options.profiles.zfs.enable = lib.mkEnableOption "ZFS profile";
        config = {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          system.stateVersion = "25.05";
          networking.hostId = "00000000";
          boot.initrd.systemd.enable = true;
          profiles.zfs.enable = true;
          users.users.alice = { isNormalUser = true; group = "users"; };
        };
      })
      extra
    ];
  }).config;

  # Messages of this module's failing assertions. Other modules' assertions are
  # filtered out: this minimal system is not bootable, and they are not what
  # these checks are about. `assertion` must be tested before `message` is
  # read: some nixpkgs messages only evaluate when their assertion fails.
  failedAssertions = config: map (a: a.message)
    (lib.filter (a: !a.assertion && lib.hasPrefix "profiles.zfs.pools:" a.message)
      config.assertions);

  # Evaluates `extra` and returns, for each failing assertion of this module,
  # whether its message contains `needle`. `[ true ]` means exactly one
  # assertion failed, and it was the intended one. Messages are wrapped, so
  # `needle` must not span a line break in the message source.
  failsWith = needle: extra: map (lib.hasInfix needle) (failedAssertions (eval extra));

  keyFile = { keyFile = "/run/keys/k"; keyFormat = "passphrase"; };

  # A root pool using disko, with `extra` datasets.
  rpoolWith = datasets: {
    profiles.zfs.pools.rpool = {
      disko = { };
      datasets = { "root".properties.mountpoint = "/"; } // datasets;
    };
  };

  routing = eval {
    imports = [
      (rpoolWith {
        "home".properties.mountpoint = "/home";
        "data" = { mountedBy = "zfs"; properties.mountpoint = "/data"; };
        "crypt" = {
          encryption = { external = true; keyFormat = "passphrase"; };
          properties.mountpoint = "none";
        };
        "crypt/alice" = { mountedBy = "explicit"; properties.mountpoint = "/home/alice"; };
      })
    ];
    profiles.zfs.pools = {
      # Covers every kind of dataset on a data pool, so that the runner built
      # below exercises every branch of its generated script.
      tank.datasets = {
        "media".properties.mountpoint = "/srv/media";
        "shares" = { owner = "alice"; mode = "0700"; properties.mountpoint = "/srv/shares"; };
        "scratch" = { mountedBy = "zfs"; owner = "alice"; properties.mountpoint = "/srv/scratch"; };
        "manual" = { mountedBy = "explicit"; properties.mountpoint = "/srv/manual"; };
        "vault" = { encryption = keyFile; properties.mountpoint = "none"; };
        "vault/docs".properties.mountpoint = "/srv/docs";
      };
      cold = {
        importAtBoot = false;
        datasets."archive" = { mountedBy = "zfs"; properties.mountpoint = "/srv/archive"; };
      };
      empty = { };
    };
    systemd.services = lib.mapAttrs (_: path: { requiresZfsMounts = [ path ]; script = "true"; }) {
      uses-home = "/home/bob";
      uses-data = "/data/x";
      uses-docs = "/srv/docs/2026";
      uses-scratch = "/srv/scratch";
    };
  };
  services = routing.systemd.services;
  namesWithPrefix = prefix: attrs: lib.filter (lib.hasPrefix prefix) (lib.attrNames attrs);
  depsOf = s: {
    inherit (services.${s}) requires after;
    mountsFor = services.${s}.unitConfig.RequiresMountsFor or [ ];
  };
  dataPoolMountOptions = [ "nofail" "x-systemd.requires=zfs-datasets-tank.service" ];

  # A root pool whose devices are not declared with disko.
  plainRoot = eval {
    profiles.zfs.pools.rpool.datasets = {
      "root".properties.mountpoint = "/";
      "home".properties.mountpoint = "/home";
    };
  };

  # A data pool whose devices are declared with disko.
  diskoData = eval {
    profiles.zfs.pools.tank = {
      disko = { };
      properties.compression = "lz4";
      datasets."media".properties.mountpoint = "/srv/media";
    };
  };

  tests = {
    testNoFailedAssertions = {
      expr = map failedAssertions [ routing plainRoot diskoData ];
      expected = [ [ ] [ ] [ ] ];
    };

    # nixpkgs agrees with the classification (see the header). `cold` has no
    # import unit because `importAtBoot = false` and none of its datasets is in
    # `fileSystems`.
    testStage2ImportUnitsOnlyForDataPools = {
      expr = namesWithPrefix "zfs-import-" services;
      expected = [ "zfs-import-empty" "zfs-import-tank" ];
    };
    testInitrdImportUnitsOnlyForRootPools = {
      expr = map (c: namesWithPrefix "zfs-import-" c.boot.initrd.systemd.services)
        [ routing plainRoot ];
      expected = [ [ "zfs-import-rpool" ] [ "zfs-import-rpool" ] ];
    };

    testExtraPoolsExcludeRootPools = {
      expr = routing.boot.zfs.extraPools;
      expected = [ "empty" "tank" ];
    };

    # Every data pool with something declared gets a runner and a target,
    # encrypted or not; root pools and empty pools get neither.
    testRunnersOnlyForDeclaredDataPools = {
      expr = {
        services = namesWithPrefix "zfs-datasets-" services;
        targets = namesWithPrefix "zfs-datasets-" routing.systemd.targets;
      };
      expected = {
        services = [ "zfs-datasets-cold" "zfs-datasets-tank" ];
        targets = [ "zfs-datasets-cold" "zfs-datasets-tank" ];
      };
    };

    # A root pool's datasets are rendered into disko. Only systemd-mounted
    # ones get disko's top-level `mountpoint` (and so a `fileSystems` entry);
    # explicitly mounted ones get `canmount=noauto`.
    testRootPoolRenderedIntoDisko = {
      expr = lib.mapAttrs
        (_: ds: {
          inherit (ds) mountpoint;
          property = ds.options.mountpoint or null;
          canmount = ds.options.canmount or null;
        })
        # `__root` is disko's internal stand-in for the pool's root dataset.
        (removeAttrs routing.disko.devices.zpool.rpool.datasets [ "__root" ]);
      expected = {
        "root" = { mountpoint = "/"; property = "/"; canmount = null; };
        "crypt" = { mountpoint = null; property = "none"; canmount = null; };
        "crypt/alice" = { mountpoint = null; property = "/home/alice"; canmount = "noauto"; };
        "data" = { mountpoint = null; property = "/data"; canmount = null; };
        "home" = { mountpoint = "/home"; property = "/home"; canmount = null; };
      };
    };
    # disko, unlike disko-zfs, creates encryption roots with their encryption
    # properties, so they must be in the rendered options.
    testDiskoCreatesExternalRootEncrypted = {
      expr = {
        inherit (routing.disko.devices.zpool.rpool.datasets."crypt".options)
          encryption keyformat keylocation;
      };
      expected = { encryption = "aes-256-gcm"; keyformat = "passphrase"; keylocation = "prompt"; };
    };
    # A data pool declared with disko gets its root properties there, but
    # never its datasets; its oneshot creates those.
    testDataPoolInDiskoGetsOnlyRootProperties = {
      expr = {
        inherit (diskoData.disko.devices.zpool.tank) rootFsOptions;
        datasets = lib.attrNames (removeAttrs diskoData.disko.devices.zpool.tank.datasets [ "__root" ]);
        runner = diskoData.systemd.services ? zfs-datasets-tank;
        media = { inherit (diskoData.fileSystems."/srv/media") device options; };
      };
      expected = {
        rootFsOptions = { compression = "lz4"; };
        datasets = [ ];
        runner = true;
        media = { device = "tank/media"; options = dataPoolMountOptions; };
      };
    };

    # Systemd-mounted data pool datasets get `nofail` mounts that require the
    # pool's oneshot; ZFS-mounted and explicitly mounted ones get none.
    testDataPoolFileSystems = {
      expr = lib.mapAttrs (_: fs: { inherit (fs) device options; })
        (lib.filterAttrs (_: fs: lib.hasPrefix "tank/" fs.device) routing.fileSystems);
      expected = {
        "/srv/docs" = { device = "tank/vault/docs"; options = dataPoolMountOptions; };
        "/srv/media" = { device = "tank/media"; options = dataPoolMountOptions; };
        "/srv/shares" = { device = "tank/shares"; options = dataPoolMountOptions; };
      };
    };
    # Without disko, this module generates a root pool's `fileSystems`
    # entries itself, in the same form as disko's, and hands its datasets to
    # the early service directly.
    testRootPoolWithoutDisko = {
      expr = {
        root = { inherit (plainRoot.fileSystems."/") device; zfsutil = lib.elem "zfsutil" plainRoot.fileSystems."/".options; };
        early = lib.attrNames plainRoot.disko.zfs.settings.datasets;
        ignored = plainRoot.disko.zfs.settings.ignoredDatasets;
      };
      expected = {
        root = { device = "rpool/root"; zfsutil = true; };
        early = [ "rpool/home" "rpool/root" ];
        ignored = [ "rpool" ];
      };
    };

    # Root pools are reconciled by the early service; data pools are kept away
    # from it entirely.
    testEarlyServiceGetsRootPoolDatasetsFromDisko = {
      expr = lib.attrNames routing.disko.zfs.settings.datasets;
      expected = [ "rpool" "rpool/crypt" "rpool/crypt/alice" "rpool/data" "rpool/home" "rpool/root" ];
    };
    testEarlyServiceIgnoresDataPools = {
      expr = routing.disko.zfs.settings.ignoredDatasets;
      expected = [ "cold" "cold/*" "tank" "tank/*" "rpool" ];
    };

    testRunnerRequiresImportUnit = {
      expr = map (p: services."zfs-datasets-${p}".requires) [ "tank" "cold" ];
      expected = [ [ "zfs-import-tank.service" ] [ ] ];
    };

    testRunnerOrderedAfterAgenix = {
      expr = lib.elem "agenix-install-secrets.service" services.zfs-datasets-tank.after;
      expected = true;
    };

    testConsumerOfSystemdMountOnRootPool = {
      expr = depsOf "uses-home";
      expected = { requires = [ ]; after = [ ]; mountsFor = [ "/home/bob" ]; };
    };
    testConsumerOfZfsMountOnRootPool = {
      expr = depsOf "uses-data";
      expected = { requires = [ "zfs-mount.service" ]; after = [ "zfs-mount.service" ]; mountsFor = [ ]; };
    };
    testConsumerOfSystemdMountOnDataPool = {
      expr = depsOf "uses-docs";
      expected = { requires = [ ]; after = [ ]; mountsFor = [ "/srv/docs/2026" ]; };
    };
    testConsumerOfZfsMountOnDataPool = {
      expr = depsOf "uses-scratch";
      expected = {
        requires = [ "zfs-datasets-tank.target" ];
        after = [ "zfs-datasets-tank.target" "zfs-datasets-tank.service" ];
        mountsFor = [ ];
      };
    };
    testConsumerOfExplicitMountIsAnError = {
      expr = (builtins.tryEval (eval {
        profiles.zfs.pools = routing.profiles.zfs.pools;
        systemd.services.bad = { requiresZfsMounts = [ "/home/alice" ]; script = "true"; };
      }).systemd.services.bad.after).success;
      expected = false;
    };

    # The early service must refuse to create a missing external encryption
    # root on a root pool, since it would create it unencrypted.
    testEarlyServiceChecksExternalRoots = {
      expr = lib.hasInfix "rpool/crypt" services.disko-zfs.preStart;
      expected = true;
    };
    testNoCheckWithoutExternalRoots = {
      expr = diskoData.systemd.services.disko-zfs.preStart;
      expected = "";
    };

    testNixpkgsMustAgree = {
      expr = failsWith "backs filesystems needed" {
        fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; };
        profiles.zfs.pools.rpool.datasets."home".properties.mountpoint = "/home";
      };
      expected = [ true ];
    };
    testDiskoDeclaredPoolMustSetDisko = {
      expr = failsWith "but does not set `disko`" {
        disko.devices.zpool.tank = { };
        profiles.zfs.pools.tank.datasets."media".properties.mountpoint = "/srv/media";
      };
      expected = [ true ];
    };
    testNoDatasetsInDiskoDevices = {
      expr = failsWith "also declares datasets in" {
        disko.devices.zpool.tank.datasets."extra" = { type = "zfs_fs"; };
        profiles.zfs.pools.tank = {
          disko = { };
          datasets."media".properties.mountpoint = "/srv/media";
        };
      };
      expected = [ true ];
    };
    testBootPathMustBeSystemdMounted = {
      expr = failsWith "which is needed for boot" {
        profiles.zfs.pools.rpool.datasets."root" = {
          mountedBy = "zfs";
          properties.mountpoint = "/";
        };
      };
      expected = [ true ];
    };
    testRootPoolRejectsKeyFile = {
      expr = failsWith "uses a key file managed by" (rpoolWith {
        "secret" = { encryption = keyFile; properties.mountpoint = "none"; };
      });
      expected = [ true ];
    };
    testRootPoolExternalRootNeedsKeyFormat = {
      expr = failsWith "so that disko can create it" (rpoolWith {
        "secret" = { encryption.external = true; properties.mountpoint = "none"; };
      });
      expected = [ true ];
    };
    testRootPoolRejectsOwnership = {
      expr = failsWith "declares a POSIX owner" (rpoolWith {
        "home" = { owner = "alice"; properties.mountpoint = "/home"; };
      });
      expected = [ true ];
    };
    testRootPoolRejectsImportAtBootFalse = {
      expr = failsWith "`importAtBoot = false`" {
        imports = [ (rpoolWith { }) ];
        profiles.zfs.pools.rpool.importAtBoot = false;
      };
      expected = [ true ];
    };
    testUnimportedDataPoolRejectsSystemdMounts = {
      expr = failsWith "but has systemd-mounted datasets" {
        profiles.zfs.pools.cold = {
          importAtBoot = false;
          datasets."archive".properties.mountpoint = "/srv/archive";
        };
      };
      expected = [ true ];
    };
  };

  failures = lib.runTests tests;
in
{
  zfs-datasets = pkgs.runCommand "zfs-datasets-checks"
    {
      nativeBuildInputs = [ pkgs.jq ];
      # Building the unit builds the runner script, which shellchecks it.
      unit = routing.systemd.units."zfs-datasets-tank.service".unit;
      runner = services.zfs-datasets-tank.serviceConfig.ExecStart;
    }
    (if failures != [ ] then
      throw ''
        profiles.zfs checks failed:
        ${lib.generators.toPretty { } failures}
      '' else ''
      # The properties the runner applies, as the ZFS side of `mountedBy`:
      # systemd-mounted data pool datasets are `legacy` (systemd mounts them),
      # and ZFS-mounted and explicit ones are `noauto` (so `zfs-mount.service`
      # does not).
      spec="$(grep -o '/nix/store/[a-z0-9]*-zfs-datasets-tank-spec.json' "$runner" | head -n1)"
      jq -e '.datasets as $d
        | $d["tank/media"].properties.mountpoint == "legacy"
        and $d["tank/vault/docs"].properties.mountpoint == "legacy"
        and $d["tank/scratch"].properties == { mountpoint: "/srv/scratch", canmount: "noauto" }
        and $d["tank/manual"].properties == {
          mountpoint: "/srv/manual", canmount: "noauto", "org.openzfs.systemd:ignore": "on" }
      ' "$spec"
      # The runner mounts only ZFS-mounted datasets; systemd mounts the rest.
      grep -q 'zfs mount tank/scratch' "$runner"
      ! grep -q 'zfs mount tank/media' "$runner"
      touch $out
    '');
}
