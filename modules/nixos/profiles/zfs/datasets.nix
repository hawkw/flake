# Manages ZFS datasets declaratively (`profiles.zfs.pools`), including datasets
# encrypted with agenix-provided keys.
#
# == Theory of operation ==
#
# This is a thin wrapper over [`disko-zfs`](https://github.com/numtide/disko-zfs)
# that lets every dataset for a pool be declared in one place, and then routes
# each pool to the mechanism that can actually manage it:
#
#   * **Unencrypted pools** are handed to the stock `disko-zfs` service, which
#     runs early in boot (before `local-fs-pre.target`).
#   * **Pools containing any encrypted dataset** are managed *in their entirety*
#     by a late, per-pool oneshot (`zfs-datasets-<pool>.service`), ordered after
#     the pool's import. The encryption passphrases are agenix secrets, which
#     are unavailable when the early `disko-zfs` service runs; there is no
#     agenix unit to order against (decryption happens during activation), so
#     the oneshot instead runs late --- at multi-user, by which point activation
#     has installed the secrets --- and fails loudly if a key file is missing.
#
# Consumers of an encrypted pool must declare both `requires` and `after` on
# `zfs-datasets-<pool>.target`. If unlock or mount fails, the target is not
# reached and those services stay stopped; `after` alone would let them start
# anyway and write into the empty mountpoint directory on the root filesystem.
# The rest of the system boots normally either way.
#
# Two operational invariants fall out of this design:
#
#   * **The configuration owns every local property** of a declared dataset.
#     Reconciliation reverts (via `zfs inherit`) any local property set by hand
#     that is not declared here. Set properties in the configuration, or add
#     them to `disko.zfs.settings.ignoredProperties`.
#   * **Layout changes are applied manually**, with `systemctl restart
#     zfs-datasets-<pool>.service` (or on the next boot) --- never implicitly
#     by `nixos-rebuild switch`. See the `restartIfChanged` comment in
#     `mkService` for why.
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
    optional optionalString filterAttrs attrNames;

  cfg = config.profiles.zfs;

  # Properties that are intrinsic to encryption and must never be touched by
  # `disko-zfs` property reconciliation: `encryption`/`keyformat`/
  # `encryptionroot`/`keystatus` are read-only after creation (reconciling them
  # errors), and `keylocation`/`pbkdf2iters`/`pbkdf2salt` are set at
  # create/key-load time --- inheriting them away would break unattended unlock.
  # (`keylocation` *is* reconciled, but by the runner itself, from the
  # `encryption.keyFile` option; see `createDatasets`.)
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
        owner = null;
        group = null;
        mode = null;
      }
    ++ mapAttrsToList
      (rel: d: {
        name = "${pool}/${rel}";
        inherit (d) properties encryption owner group mode;
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
  # Sorted by *mountpoint* path depth, not dataset depth: mount ordering must
  # follow the shape of the mount tree, and a shallow dataset may declare a
  # mountpoint nested under a deeper dataset's mountpoint.
  mountable = ds:
    let
      wanted = d:
        hasPrefix "/" (d.properties.mountpoint or "none")
        && (d.properties.canmount or "on") != "off";
      mountDepth = d: length (splitString "/" d.properties.mountpoint);
    in
    sort (a: b: mountDepth a < mountDepth b) (filter wanted ds);

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
          # Lazy: only forced in the encrypted branch, where `d.encryption` is
          # known non-null.
          let keyLoc = escapeShellArg "file://${d.encryption.keyFile}"; in
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
                -o keylocation=${keyLoc} \
                ${propArgs d} ${escapeShellArg d.name}
              echo ${escapeShellArg d.name} >> "$RUNTIME_DIRECTORY/created-datasets"
            fi
            # `keylocation` is pool state written at creation. If the key file
            # moves (e.g. the agenix secret is renamed), unlock must follow the
            # *configuration* rather than fail against the stale stored path,
            # so reconcile it here before loading the key. (disko-zfs must
            # never touch it --- see `cryptoProperties`.)
            if [ "$(zfs get -H -o value keylocation ${escapeShellArg d.name})" != ${keyLoc} ]; then
              echo "updating keylocation for ${d.name}"
              zfs set keylocation=${keyLoc} ${escapeShellArg d.name}
            fi
            if [ "$(zfs get -H -o value keystatus ${escapeShellArg d.name})" != available ]; then
              echo "loading key for ${d.name}"
              zfs load-key ${escapeShellArg d.name}
            fi
          '' else ''
            if ! zfs list -H -o name ${escapeShellArg d.name} >/dev/null 2>&1; then
              echo "creating dataset ${d.name}"
              zfs create ${propArgs d} ${escapeShellArg d.name}
              echo ${escapeShellArg d.name} >> "$RUNTIME_DIRECTORY/created-datasets"
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

      # Declared ownership is ordinary POSIX metadata on the dataset's root
      # directory, applied exactly once --- when this run *created* the dataset
      # (tracked via $RUNTIME_DIRECTORY/created-datasets) --- and never
      # reconciled afterwards: later ownership changes are user data, and
      # re-chowning on every boot would fight them. Runs after the mount step,
      # since an unmounted dataset root has no path to chown.
      applyOwnership = concatMapStringsSep "\n"
        (d:
          let
            chownArg =
              if d.owner != null then
                (if d.group != null then "${d.owner}:${d.group}" else d.owner)
              else ":${d.group}";
          in
          ''
            if grep -qxF ${escapeShellArg d.name} "$RUNTIME_DIRECTORY/created-datasets"; then
              echo "applying declared ownership to ${d.name} (${d.properties.mountpoint})"
              ${optionalString (d.owner != null || d.group != null)
                "chown ${escapeShellArg chownArg} ${escapeShellArg d.properties.mountpoint}"}
              ${optionalString (d.mode != null)
                "chmod ${escapeShellArg d.mode} ${escapeShellArg d.properties.mountpoint}"}
            fi
          '')
        (filter (d: d.owner != null || d.group != null || d.mode != null) inPool);

      runner = pkgs.writeShellApplication {
        name = "zfs-datasets-${pool}";
        runtimeInputs = [
          config.boot.zfs.package
          config.disko.zfs.package
          pkgs.coreutils
          pkgs.gnugrep
        ];
        text = ''
          # Datasets created by *this* run, so step 4 can apply declared
          # ownership exactly once, at creation.
          touch "$RUNTIME_DIRECTORY/created-datasets"

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

          # 4. Apply declared ownership to datasets created by this run.
          ${applyOwnership}
        '';
      };
    in
    runner;

  mkService = pool: {
    description = "Create, unlock, and mount ZFS datasets on ${pool}";
    # Deliberately NOT restarted by `nixos-rebuild switch` when the runner
    # changes: switch applies changed units by stopping and starting them, the
    # stop propagates through the target's `Requires` to every consumer, and
    # unchanged consumers are not started again afterwards --- so a layout edit
    # would silently take every pool consumer down until the next boot. Apply
    # layout changes with an explicit `systemctl restart
    # zfs-datasets-<pool>.service` (an explicit restart propagates to
    # dependents *as a restart*, in dependency order), or reboot.
    restartIfChanged = false;
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
          The `keyformat` for the encryption root. Deliberately has no default:
          it must match the actual contents of {option}`keyFile`, and declaring
          `passphrase` for a raw or hex key file is **not** an error --- ZFS
          derives a key from the misread bytes and the dataset appears to work,
          but the type-the-passphrase recovery path is silently broken.
          `passphrase` (with an actual passphrase in the file) is recommended:
          the same passphrase can unlock the dataset on any machine (`zfs
          load-key -L prompt`), which keeps disaster recovery simple.
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

          The configuration owns *every* local property of a declared dataset:
          a property set by hand with `zfs set` and not declared here is
          reverted (`zfs inherit`) the next time reconciliation runs. Declare
          such properties here, or add them to
          {option}`disko.zfs.settings.ignoredProperties`.
        '';
      };

      owner = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "eliza";
        description = ''
          If set, the dataset's root directory is chowned to this user when the
          dataset is **created** (after its first mount). Ownership is ordinary
          POSIX metadata, so unlike `properties` it is *never reconciled*:
          later ownership changes are user data and are left alone. The user
          must exist in {option}`users.users` (asserted at evaluation time),
          and the dataset must declare a path mountpoint.
        '';
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "users";
        description = ''
          Group for the dataset's root directory, applied at creation like
          {option}`owner`. Must exist in {option}`users.groups` (asserted at
          evaluation time).
        '';
      };

      mode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0750";
        description = ''
          Mode (chmod) for the dataset's root directory, applied at creation
          like {option}`owner`. `0750` or `0700` is recommended for per-user
          datasets; the default directory mode (`0755`) lets every local user
          read every other user's data despite the per-user encryption roots.
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
          as well as children): a missing undeclared parent fails its children's
          creation, and an existing undeclared parent has its local properties
          stripped by `disko-zfs`'s parent expansion.
        '';
      };
    };
  };
in
{
  options.profiles.zfs.pools = mkOption {
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
      name. See the theory-of-operation comment at the top of this module.
    '';
  };

  # NOTE: the top-level config keys here are all *static*; only the nested
  # systemd unit names depend on `latePools`. Making a top-level key (or a
  # `mkMerge` list length) depend on an option value forces that option while
  # the module fixpoint is still being computed, which deadlocks (`_module.check`
  # -> our config -> the option -> `_module.check`).
  config = mkIf (cfg.enable && cfg.pools != { }) {
    assertions = concatMap
      (d:
        optional (d.owner != null)
          {
            assertion = config.users.users ? ${d.owner};
            message = ''
              profiles.zfs.pools: dataset "${d.name}" declares owner "${d.owner}",
              but no such user exists in `users.users`.'';
          }
        ++ optional (d.group != null) {
          assertion = config.users.groups ? ${d.group};
          message = ''
            profiles.zfs.pools: dataset "${d.name}" declares group "${d.group}",
            but no such group exists in `users.groups`.'';
        }
        ++ optional (d.owner != null || d.group != null || d.mode != null) {
          assertion = hasPrefix "/" (d.properties.mountpoint or "none")
          && (d.properties.canmount or "on") != "off";
          message = ''
            profiles.zfs.pools: dataset "${d.name}" declares owner/group/mode,
            but has no path mountpoint --- there is nothing to chown.'';
        })
      datasetList;

    disko.zfs.enable = lib.mkDefault true;
    boot.zfs.extraPools = attrNames (filterAttrs (_: p: p.importAtBoot) cfg.pools);
    disko.zfs.settings = {
      logLevel = lib.mkDefault "info";
      # Runtime-managed properties that `disko-zfs` should never fight over,
      # plus the encryption-intrinsic properties: the early service also
      # reconciles disko-declared pools (i.e. the root pool), and an encryption
      # root's `encryption`/`keyformat` have non-user-managed sources there ---
      # "reconciling" them is impossible and logs an error on every boot.
      ignoredProperties = lib.mkDefault
        ([ "nixos:shutdown-time" ":generation" ] ++ cryptoProperties);
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
