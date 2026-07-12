# Declarative ZFS dataset management that understands agenix-encrypted datasets.
#
# This is a thin wrapper over [`disko-zfs`](https://github.com/numtide/disko-zfs)
# that lets every dataset for a pool be declared in one place, and then routes
# each dataset to the mechanism that can actually manage it:
#
#   * **Unencrypted pools** are handed to the stock `disko-zfs` service, which
#     runs early in boot (before `local-fs-pre.target`).
#   * **Pools containing any encrypted dataset** are managed *in their entirety*
#     by a late, per-pool oneshot (`zfs-datasets-<pool>.service`). The oneshot
#     runs after the pool is imported *and* after agenix has decrypted secrets,
#     so it can read the encryption passphrases (which are agenix secrets and
#     therefore unavailable when the early `disko-zfs` service runs).
#
# Why a late oneshot rather than the stock service for encrypted pools:
# `disko-zfs` runs `before local-fs-pre.target`, which is ordered *before*
# agenix decrypts secrets. It also has no "reconcile-but-never-create" mode and
# will happily create a missing encryption root *unencrypted* (its
# auto-parent-creation uses empty properties). Forcing it to run after agenix
# would create a systemd ordering cycle (`disko-zfs` -> `local-fs-pre.target`
# -> ... -> agenix -> `disko-zfs`). The late oneshot sidesteps all of this.
#
# A whole encrypted pool is routed to the oneshot (not just its encrypted
# subtree) so that the pool is reconciled by a *single* `disko-zfs` invocation.
# Splitting a pool between the early service and the oneshot runs afoul of
# `disko-zfs`'s `expand_sub_datasets`, which injects empty-property parent
# datasets and would then inherit-away (clobber) the real properties of shared
# ancestors.
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkOption mkIf types mapAttrsToList filter elem map head splitString unique
    sort length concatMap concatLists concatMapStringsSep concatStringsSep
    escapeShellArg listToAttrs nameValuePair getExe hasPrefix removeAttrs
    optional filterAttrs attrNames;

  cfg = config.zfsDatasets;

  # Properties that are intrinsic to encryption and must never be touched by
  # `disko-zfs` property reconciliation: `encryption`/`keyformat`/
  # `encryptionroot`/`keystatus` are read-only after creation (reconciling them
  # errors), and `keylocation`/`pbkdf2iters`/`pbkdf2salt` are set at
  # create/key-load time --- inheriting them away would break unattended unlock.
  cryptoProperties = [
    "encryption"
    "keyformat"
    "keylocation"
    "keystatus"
    "encryptionroot"
    "pbkdf2iters"
    "pbkdf2salt"
  ];

  # Flatten `pools.<name>.{properties,datasets}` into a single list of records
  # carrying each dataset's *full* name: `{ name; properties; encryption; }`. The
  # pool root is included only when it has declared properties (see
  # `unmanagedRoots`).
  poolDatasets = pool: pcfg:
    optional (pcfg.properties != { })
      {
        name = pool;
        inherit (pcfg) properties;
        encryption = null;
      }
    ++ mapAttrsToList
      (rel: d: {
        name = "${pool}/${rel}";
        inherit (d) properties encryption;
      })
      pcfg.datasets;

  datasetList = concatLists (mapAttrsToList poolDatasets cfg.pools);

  # A dataset is an *encryption root* iff it has an `encryption` block. Testing
  # `!= null` only forces the option to WHNF (null vs. submodule), NOT the key
  # file inside it --- important because the key file is typically
  # `config.age.secrets.*.path`, and forcing that while computing the set of
  # config keys (below) would create a module-system evaluation cycle.
  encryptionRoots = filter (d: d.encryption != null) datasetList;

  poolOf = name: head (splitString "/" name);
  depth = name: length (splitString "/" name);

  # Pools containing at least one encryption root are managed by a late oneshot;
  # every other pool goes through the stock early `disko-zfs` service.
  latePools = unique (map (d: poolOf d.name) encryptionRoots);
  isLate = d: elem (poolOf d.name) latePools;

  earlyDatasets = filter (d: !isLate d) datasetList;

  # Pool roots with children but no declared properties. They must be ignored, or
  # `disko-zfs`'s `expand_sub_datasets` would add an empty-property root entry and
  # then inherit-away (clobber) the pool root's real local properties.
  unmanagedRoots = attrNames
    (filterAttrs (_: pcfg: pcfg.properties == { } && pcfg.datasets != { }) cfg.pools);

  datasetSpec = d: nameValuePair d.name { inherit (d) properties; };

  # Render a dataset's declared properties as `-o key=value` arguments,
  # defensively dropping any encryption-intrinsic property (those are handled
  # from the encryption options, not the free-form `properties` attrset).
  propArgs = d:
    concatStringsSep " "
      (mapAttrsToList (k: v: "-o ${escapeShellArg "${k}=${toString v}"}")
        (removeAttrs d.properties cryptoProperties));

  # Datasets that declare a real (path) mountpoint and are allowed to mount.
  mountable = ds:
    let
      wanted = d:
        hasPrefix "/" (d.properties.mountpoint or "none")
        && (d.properties.canmount or "on") != "off";
    in
    sort (a: b: depth a.name < depth b.name) (filter wanted ds);

  mkRunner = pool:
    let
      inPool = filter (d: poolOf d.name == pool) datasetList;
      # Create parents before children so that, by the time we create a child
      # dataset, its parent (and, for encrypted children, the parent's now-loaded
      # key) already exists.
      parentFirst = sort (a: b: depth a.name < depth b.name) inPool;

      spec = (pkgs.formats.json { }).generate "zfs-datasets-${pool}-spec.json" {
        logLevel = "info";
        ignoredDatasets = optional (elem pool unmanagedRoots) pool;
        ignoredProperties = cryptoProperties;
        datasets = listToAttrs (map datasetSpec inPool);
      };

      createDatasets = concatMapStringsSep "\n"
        (d:
          if d.encryption != null then ''
            if [ ! -e ${escapeShellArg d.encryption.keyFile} ]; then
              echo "key file ${d.encryption.keyFile} for ${d.name} is missing (is agenix ready?)" >&2
              exit 1
            fi
            if ! zfs list -H -o name ${escapeShellArg d.name} >/dev/null 2>&1; then
              echo "creating encryption root ${d.name}"
              zfs create \
                -o encryption=${escapeShellArg d.encryption.algorithm} \
                -o keyformat=${escapeShellArg d.encryption.keyFormat} \
                -o keylocation=file://${d.encryption.keyFile} \
                ${propArgs d} ${escapeShellArg d.name}
            fi
            if [ "$(zfs get -H -o value keystatus ${escapeShellArg d.name})" != available ]; then
              echo "loading key for ${d.name}"
              zfs load-key ${escapeShellArg d.name}
            fi
          '' else ''
            if ! zfs list -H -o name ${escapeShellArg d.name} >/dev/null 2>&1; then
              echo "creating dataset ${d.name}"
              zfs create ${propArgs d} ${escapeShellArg d.name}
            fi
          '')
        parentFirst;

      mountDatasets = concatMapStringsSep "\n"
        (d: ''
          if [ "$(zfs get -H -o value mounted ${escapeShellArg d.name})" != yes ]; then
            echo "mounting ${d.name} at ${d.properties.mountpoint}"
            zfs mount ${escapeShellArg d.name}
          fi
        '')
        (mountable inPool);

      runner = pkgs.writeShellApplication {
        name = "zfs-datasets-${pool}";
        runtimeInputs = [ config.boot.zfs.package config.disko.zfs.package ];
        text = ''
          # 1. Create every declared dataset (parent-first) that does not yet
          #    exist, and load encryption keys. This is done here, late, because
          #    the passphrase files are agenix secrets that are unavailable when
          #    the early disko-zfs service runs. Creating the datasets ourselves
          #    (rather than letting disko-zfs do it) is what guarantees an
          #    encryption root is never accidentally created unencrypted.
          ${createDatasets}

          # 2. Reconcile properties with disko-zfs. Every dataset already exists
          #    after step 1, so disko-zfs only sets/inherits properties (drift
          #    from the declared spec). We feed it a snapshot of the pool via
          #    `--file` so it neither touches nor reports on other pools, and
          #    the encryption-intrinsic properties are in `ignoredProperties`.
          zfs get all -t filesystem --json --json-int -r ${escapeShellArg pool} \
            > "$RUNTIME_DIRECTORY/actual.json"
          disko-zfs --file "$RUNTIME_DIRECTORY/actual.json" --log-level info \
            apply --spec ${spec}

          # 3. Mount datasets that declare a filesystem mountpoint.
          ${mountDatasets}
        '';
      };
    in
    runner;

  mkService = pool: {
    description = "Create, unlock, and mount ZFS datasets on ${pool}";
    after = [ "zfs-import-${pool}.service" "zfs-mount.service" ];
    requires = [ "zfs-import-${pool}.service" ];
    # Bind the target to *success* of this service (Requires, not Wants) so that
    # consumers ordered on the target do not start if unlock/mount fails --- this
    # is what prevents a service from silently writing into the underlying
    # (root-pool) directory when the data pool is unavailable.
    requiredBy = [ "zfs-datasets-${pool}.target" ];
    before = [ "zfs-datasets-${pool}.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "zfs-datasets-${pool}";
      ExecStart = getExe (mkRunner pool);
    };
  };

  # A target consumers can order against (`after`/`requires`) to guarantee the
  # pool's datasets are unlocked and mounted before they start. It is only
  # `wantedBy` (not required by) multi-user.target, so a failure to bring up the
  # data pool never blocks the rest of the system from booting.
  mkTarget = pool: {
    description = "ZFS datasets on ${pool} are unlocked and mounted";
    wantedBy = [ "multi-user.target" ];
  };

  perPool = f: listToAttrs (map (p: nameValuePair "zfs-datasets-${p}" (f p)) latePools);

  encryptionSubmodule = types.submodule {
    options = {
      keyFile = mkOption {
        type = types.str;
        example = lib.literalExpression "config.age.secrets.moonpool-system-pass.path";
        description = ''
          Path to the file containing the encryption key (typically an agenix
          secret's `.path`). The dataset is created with `keylocation =
          file://<this path>` and unlocked from it at boot.
        '';
      };

      keyFormat = mkOption {
        type = types.enum [ "passphrase" "hex" "raw" ];
        description = ''
          The `keyformat` for the encryption root. This is **required** and has
          no default: it must match the actual contents of {option}`keyFile`
          (mis-declaring it silently derives the wrong key). `passphrase` is
          recommended --- the same passphrase can unlock the dataset on any
          machine (`zfs load-key -L prompt`), which keeps disaster recovery
          simple.
        '';
      };

      algorithm = mkOption {
        type = types.str;
        default = "aes-256-gcm";
        description = "The `encryption` suite for the encryption root.";
      };
    };
  };

  datasetSubmodule = types.submodule {
    options = {
      encryption = mkOption {
        type = types.nullOr encryptionSubmodule;
        default = null;
        example = lib.literalExpression ''
          { keyFile = config.age.secrets.moonpool-system-pass.path; keyFormat = "passphrase"; }
        '';
        description = ''
          If set, this dataset is an *encryption root*: it is created with the
          given key, and the entire pool it lives on is managed by a late oneshot
          rather than the early `disko-zfs` service (so the key file, an agenix
          secret, is available when the dataset is created and unlocked).

          Leave unset for unencrypted datasets and for children of an encryption
          root (children inherit their parent's key automatically).
        '';
      };

      properties = mkOption {
        type = types.attrsOf (types.either types.str types.int);
        default = { };
        example = { mountpoint = "/srv/media"; "com.sun:auto-snapshot" = "false"; };
        description = ''
          ZFS properties to set on the dataset. Encryption-intrinsic properties
          (`encryption`, `keyformat`, `keylocation`, ...) are managed
          automatically from the encryption options and must not be set here.
        '';
      };
    };
  };

  poolSubmodule = types.submodule {
    options = {
      importAtBoot = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to import this pool at boot (adds it to
          {option}`boot.zfs.extraPools`). Do not enable this for the root pool,
          which is imported from the initrd.
        '';
      };

      properties = mkOption {
        type = types.attrsOf (types.either types.str types.int);
        default = { };
        example = { mountpoint = "none"; compression = "lz4"; };
        description = ''
          ZFS properties for the pool's *root* dataset (equivalent to disko's
          `rootFsOptions`). If left empty while child datasets are declared, the
          root dataset is left untouched (neither created nor reconciled).
        '';
      };

      datasets = mkOption {
        type = types.attrsOf datasetSubmodule;
        default = { };
        description = ''
          Datasets in this pool, keyed by their name *relative to the pool* (e.g.
          `"ds1/media"`). Declare every intermediate dataset explicitly (parents
          as well as children).
        '';
      };
    };
  };
in
{
  options.zfsDatasets.pools = mkOption {
    type = types.attrsOf poolSubmodule;
    default = { };
    example = lib.literalExpression ''
      {
        moonpool = {
          properties.mountpoint = "none";
          datasets = {
            "ds1/media".properties.mountpoint = "/srv/media";
            "ds1/secret" = {
              encryption = {
                keyFile = config.age.secrets.moonpool-secret.path;
                keyFormat = "passphrase";
              };
              properties.mountpoint = "/srv/secret";
            };
          };
        };
      }
    '';
    description = ''
      ZFS pools whose datasets should be managed declaratively, keyed by pool
      name.
    '';
  };

  # NOTE: the top-level config keys here are all *static*; only the nested
  # systemd unit names depend on `latePools`. Making a top-level key (or a
  # `mkMerge` list length) depend on an option value forces that option while
  # the module fixpoint is still being computed, which deadlocks (`_module.check`
  # -> our config -> the option -> `_module.check`).
  config = mkIf (cfg.pools != { }) {
    disko.zfs.enable = lib.mkDefault true;
    boot.zfs.extraPools = attrNames (filterAttrs (_: p: p.importAtBoot) cfg.pools);
    disko.zfs.settings = {
      logLevel = lib.mkDefault "info";
      # Runtime-managed properties that `disko-zfs` should never fight over.
      ignoredProperties = lib.mkDefault [ "nixos:shutdown-time" ":generation" ];
      # Unencrypted pools go through the stock (early) disko-zfs service.
      datasets = listToAttrs (map datasetSpec earlyDatasets);
      # Keep the early service away from pools the late oneshot owns, and from
      # any unmanaged (undeclared) pool root, so it neither tries to create their
      # datasets nor clobbers/destroys them.
      ignoredDatasets =
        concatMap (p: [ p "${p}/*" ]) latePools
        ++ filter (p: !(elem p latePools)) unmanagedRoots;
    };
    systemd.services = perPool mkService;
    systemd.targets = perPool mkTarget;
  };
}
