# Declarative ZFS dataset management extending `disko-zfs` with typed dataset
# properties and support for agenix-provided dataset encryption keys.
#
# == Theory of operation ==
#
# This is a wrapper around [`disko-zfs`](https://github.com/numtide/disko-zfs)
# that lets every dataset in a pool be declared in one place, and then
# configures the mechanism to manage that pool. How the pool is managed depends
# on its encryption properties:
#
# * unencrypted pools are managed by the stock `disko-zfs` service, which runs
#   early in boot (before `local-fs-pre.target`);
# * pools containing an encryption root are managed by a late, per-pool
#   oneshot service (`zfs-datasets-<pool>.service`), which runs after the pool
#   is imported. This service invokes `disko-zfs` to create missing datasets and
#   reconcile properties, loads keys, and mounts the datasets.
#
# The separate oneshot service is necessary when the encryption keys are
# `agenix` secrets. `agenix` installs secrets in an activation script, so there
# is no systemd unit an early service could depend on to ensure that the
# reconcilation occurs after the pool is unlocked. The stock `disko-zfs` service
# runs before `local-fs-pre.target`, at which time, the agenix keys are not
# decrypted, and therefore, the encrypted datasets are not unlocked.
# The oneshot service in this module runs at `multi-user.target`, instead.
#
# `disko-zfs`'s stock service also cannot safely create encryption roots. ZFS
# encryption properties are read-only after creation, and therefore must be
# ignored when dataset properties are reconciled. Unfortunately, ignoring them
# from reconciliation also omits them from `disko-zfs`'s `zfs create` invocation
# when the dataset does not exist. That means that an encryption root that does
# not yet exist would be created unencrypted. The oneshot creates encryption
# roots itself and configures `disko-zfs` to ignore encryption-related
# properties.
#
# Pools containing one or more encryption root datasets are *always* managed by
# a single late oneshot service. Splitting work between the early stock
# disko-zfs service and the oneshot is unsafe, because when `disko-zfs`'s
# `expand_sub_datasets` creates missing parent datasets, it does not set any
# properties. Therefore, this could accidentally replace the declared properties
# of a dataset created by the other service.
#
# == Usage Notes ==
#
# All local properties on datasets declared using this module are "owned" by
# this module unless explicitly ignored. Just like with standard `disko-zfs`,
# reconciling a pool's config will revert (using `zfs inherit`) any property set
# by hand and not declared here.
#
# Therefore, all properties **must** either be declared here or added to
# `disko.zfs.settings.ignoredProperties`.
#
# === Services which depend on encrypted pool datasets ===
#
# A service which requires filesystems on an encrypted pool **must** declare
# both `requires` and `after` on `zfs-datasets-<pool>.target`, or else it may be
# started before that dataset is unlocked. This is necessary if the pool
# contains any encrypted datasets, **even if the dataset that the service
# depends on is not encrypted**.
#
# Setting `requires` is necessary to prevent the service from starting when
# unlocking the dataset fails. `after` without `requires` only establishes
# *ordering*, so the service would still run after a failed oneshot and write
# into the empty mountpoint directory on the root filesystem. A failed dataset
# unlock does not block the rest of boot.
#
# Services that require filesystems on encrypted datasets may declare their
# dependencies using the `requiresZfsMounts` setting from this module, like:
#
# ```
# systemd.services.<name>.requiresZfsMounts = [ "/srv/path" ];
# ```
#
# Each path is resolved to the declared dataset with the longest matching
# mountpoint prefix, and adds the `requires` and `after` entries to the service.
# If the path is not part of a dataset managed by this module, this will produce
# an evaluation error.
#
# `nixos-rebuild switch` applies dataset changes by reloading the unit (see
# `reloadIfChanged` in `mkService`). Existing consumers remain running while
# datasets are reconciled. A service added in the same switch as a dataset it
# consumes can start before the reload creates that dataset. Services that use
# `requiresZfsMounts` wait for the reload, so they do not have this race. A
# service with hand-written dependencies on only the target may need one
# `systemctl start` after the switch.
#
# === Immutable mountpoint underlays ===
#
# Before mounting a dataset, the runner makes the mountpoint underlay directory
# immutable (`chattr +i`). While a dataset is unmounted, writes to its
# mountpoint fail with `EPERM`, even for root. This is intended to protect
# against non-empty underlay directories preventing the filesystem from being
# mounted. When the dataset is mounted, the immutable directory is overlayed by
# the mounted filesystem.
#
# There is one important operational consideration that results from this: if a
# dataset's mountpoint *changes*, this module will attempt to remove the old
# immutable underlay directory. Typically, this occurs automatically, but on the
# off chance that the underlay directory is non-empty, this module will refuse
# to remove it, since, well, you might still want whatever's in there. Normally,
# this shouldn't happen, since the non-empty underlay prevents the dataset from
# being mounted in the first place, but this can occur if a mountpoint was
# *accidentally* set to a non-empty underlay. If this *does* occur, note that
# the underlay directory will still be immutable, so you will have to manually
# run `chattr -i <path>` to make it mutable again.
#
# == Typed properties ==
#
# ZFS properties can be set using `config.profiles.zfs.pools.<pool>.properties`
# (for pool-level defaults) and
# `config.profiles.zfs.pools.<pool>.datasets.<dataset>.properties` (for
# individual datasets). These are attrsets containing both freeform options (Nix
# RFC 42 style) *and* typed options representing ZFS properties. The typed
# options are used for ZFS properties that are either commonly used, require
# multiple ZFS properties to configure, or are easy to misspell.
#
# The danger of typos or misspellings is worse for ZFS *user* properties (i.e.
# anything with `:` in its name, such as `com.sun:auto-snapshot`) than for
# native properties (those defined by ZFS). The `zfs create` or `zfs set`
# commands will fail when encountering misspelt native properties, but since
# they don't have an exhaustive list of user properties, they cannot
# distinguish between typos and intended user propertiy names. For example, if
# we were to misspell `com.sun:auto-snapshot` as `com.sun:autosnapshot`, which
# I've done a bunch of times, it would be valid as far as ZFS is concerned,
# and the zfs-autosnapshot service that consumes that property will just never
# see it, which sucks. Thus, typed properties help to protect against stuff
# like this. They also encode the expected *values* of those properties: for
# example, `atime` expects `on` or `off`, while `com.sun:auto-snapshot`
# expects `true` or `false`, so that the user of this module doesn't have to
# remember how many different ways of spelling true/false there are.
#
# Typed properties default to `null`, meaning that they are not managed by
# this module. If they are not `null`, then they are managed by this module
# and will be set by disko-zfs reconciliation. Any attributes without a typed
# option is passed through as a freeform ZFS property verbatim.
{ config, lib, pkgs, utils, ... }:
let
  inherit (lib)
    mkOption mkIf mkMerge types mapAttrs mapAttrsToList filter elem map head
    splitString unique sort length concatMap concatLists concatMapStringsSep
    concatStringsSep escapeShellArg listToAttrs nameValuePair getExe hasPrefix
    removeAttrs removeSuffix stringLength optional optionalString filterAttrs
    attrNames attrValues;

  cfg = config.profiles.zfs;

  # Encryption properties excluded from `disko-zfs` reconciliation:
  cryptoProperties = [
    # `encryption`, `keyformat`, `encryptionroot`, and `keystatus` are read-only
    # after creation. Attempting to reconcile them will always fail.
    "encryption"
    "keyformat"
    # This module's typed attribute manages keylocation and keyformat, while
    # disko-zfs treats them as normal properties. Therefore, don't let disko-zfs
    # mess with them.
    "keylocation"
    "keystatus"
    "encryptionroot"
    # `pbkdf2iters` and `pbkdf2salt` are set when keys are loaded, and touching
    #  them will probably break things, so we mustn't mess with them.
    "pbkdf2iters"
    "pbkdf2salt"
  ];

  # Definitions of typed options for ZFS properties managed by this module (see
  # "Typed properties" in the module-level comment). These must define the
  # following:
  #  - the option's `type` and `description`,
  #  - `property`, a string with the name of the actual ZFS property the option
  #    configures,
  #  - `toZfsValue`, a function that converts the option's value to a string
  #    containing the value of the property in the format ZFS expects.
  typedProperties =
    let
      # converts a boolean value to a ZFS property value that expects the
      # strings "on" or "off".
      onOff = b: if b then "on" else "off";
      # converts a boolean value to a ZFS property value that expects the
      # strings "true" or "false".
      trueFalse = b: if b then "true" else "false";
      # option type for sizes as either an integer number of bytes or a string
      # matching the format used by ZFS (e.g. `"1M"`, `"128K"`).
      sizeType = types.either types.ints.unsigned
        (types.strMatching "[0-9]+(\\.[0-9]+)?[KMGTPkmgtp]?");
    in
    {
      mountpoint = {
        property = "mountpoint";
        toZfsValue = v: v;
        type = types.either (types.enum [ "none" "legacy" ]) (types.strMatching "/.*");
        description = ''
          Where the dataset is mounted. This must be either an absolute path,
          `none`, or `legacy`.
        '';
      };
      canmount = {
        property = "canmount";
        toZfsValue = v: v;
        type = types.enum [ "on" "off" "noauto" ];
        description = "Whether the dataset can be mounted.";
      };
      recordsize = {
        property = "recordsize";
        toZfsValue = toString;
        type = sizeType;
        description = ''
          Suggested block size cap for files in this dataset (e.g. `"1M"`,
          `"128K"`). Files smaller than this are stored as a single block of
          roughly the file's size.
        '';
      };
      specialSmallBlocks = {
        property = "special_small_blocks";
        toZfsValue = toString;
        type = sizeType;
        description = ''
          Blocks at or below this size are allocated on the pool's special vdev
          (`0` disables). Must be strictly less than the recordsize, or *all*
          data is routed to the special vdev.
        '';
      };
      quota = {
        property = "quota";
        toZfsValue = toString;
        type = types.either sizeType (types.enum [ "none" ]);
        description = "Size limit for the dataset and its descendants.";
      };
      atime = {
        property = "atime";
        # ZFS expects this property as "on" or "off", rather than "true" or
        # "false".
        toZfsValue = onOff;
        type = types.bool;
        description = "Whether to update access times on read.";
      };
      autoSnapshot = {
        property = "com.sun:auto-snapshot";
        toZfsValue = trueFalse;
        type = types.bool;
        description = ''
          If `true`, this dataset should be snapshotted by the `zfs-auto-snapshot`
          service. This sets the `com.sun.auto-snapshot` user property.
        '';
      };
      autoSnapshotFrequent = {
        property = "com.sun:auto-snapshot:frequent";
        toZfsValue = trueFalse;
        type = types.bool;
        description = ''
          Per-label override for the `frequent` (15-minute) auto-snapshot label.
          This overrides {option}`autoSnapshot` for that label only.
        '';
      };
    };

  typedPropertyNames = attrNames typedProperties;
  # Given an attrset containing both typed and freeform properties, returns an
  # attrset containing only the freeform properties.
  freeformProps = p: removeAttrs p typedPropertyNames;
  # Given an attrset containing both typed and freeform properties, returns an
  # attrset containing the generated ZFS property values for the typed
  # properties.
  typedProps = p:
    listToAttrs (concatMap
      (n:
        let t = typedProperties.${n}; in
        optional (p.${n} != null) (nameValuePair t.property (t.toZfsValue p.${n})))
      typedPropertyNames);

  # Takes an attrset containing typed and freeform properties, and converts them
  # to a freeform attrset in the form expected by disko-zfs and the zfs create
  # and mount commands emitted by this module.
  toZfsProps = p: freeformProps p // typedProps p;
  # If a property is defined both as a freeform and typed option, we cannot
  # determine which one to use. Therefore, if there are any such conflicts, we
  # emit an evaluation error.
  propertyConflicts = p: attrNames (builtins.intersectAttrs (freeformProps p) (typedProps p));

  propertiesSubmodule = types.submodule {
    freeformType = types.attrsOf (types.either types.str types.int);
    options = mapAttrs
      (_: typed: mkOption {
        type = types.nullOr typed.type;
        default = null;
        description = ''
          ${typed.description}

          Renders as the ZFS property `${typed.property}`. If this is `null`,
          then the property is not declared, and the dataset inherits it from
          its parent or the pool-level default.
        '';
      })
      typedProperties;
  };

  # Given an attrset declaring a pool (in `pools.<name>.{properties,datasets}`),
  # flattens it into records containing the following:
  #
  # - `name`: the name of the dataset or pool,
  # - `properties`: the generated properties,
  # - `conflicts`: any conflicts between typed and untyped properties, used to
  #   output evaluation errors if non-empty,
  # - `encryption`: the encryption configuration for the dataset, or null,
  # - `owner`, `group`, and `mode`  to chown the mountpoint, or `null` if not
  #    configured,
  #
  #
  # The pool root is only included here if pool-level defaults are declared.
  poolDatasets = pool: pcfg:
    let rootProps = toZfsProps pcfg.properties; in
    optional (rootProps != { })
      {
        name = pool;
        properties = rootProps;
        conflicts = propertyConflicts pcfg.properties;
        encryption = null;
        owner = null;
        group = null;
        mode = null;
      }
    ++ mapAttrsToList
      (rel: d: {
        name = "${pool}/${rel}";
        properties = toZfsProps d.properties;
        conflicts = propertyConflicts d.properties;
        inherit (d) encryption owner group mode;
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

  # Pools containing an encryption root are managed by a late oneshot. All
  # other pools are managed by the stock early `disko-zfs` service.
  latePools = unique (map (d: poolOf d.name) encryptionRoots);
  isLate = d: elem (poolOf d.name) latePools;

  earlyDatasets = filter (d: !isLate d) datasetList;

  # Pool roots with children but no declared properties. They must be ignored, or
  # `disko-zfs`'s `expand_sub_datasets` would add an empty-property root entry and
  # then inherit-away (clobber) the pool root's real local properties.
  unmanagedRoots = attrNames
    (filterAttrs
      (_: pcfg: toZfsProps pcfg.properties == { } && pcfg.datasets != { })
      cfg.pools);

  datasetSpec = d: nameValuePair d.name { inherit (d) properties; };

  # Render a dataset's declared properties as `-o key=value` arguments,
  # defensively dropping any encryption-intrinsic property (those come from the
  # encryption options, never from `properties`).
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
      # dataset, its parent already exists (and for encrypted children, so that
      # the parent's encrypted key has already been loaded).
      parentFirst = sort (a: b: depth a.name < depth b.name) inPool;

      spec = (pkgs.formats.json { }).generate "zfs-datasets-${pool}-spec.json" {
        inherit (config.disko.zfs.settings) logLevel;
        ignoredDatasets = optional (elem pool unmanagedRoots) pool;
        # The user interface for controlling property reconciliation is that
        # they may either be declared in this module, or added to
        # `disko.zfs.settings.ignoredProperties` to prevent them from being
        # reconciled. We must ensure that the late pool runner honors the same
        # list as early pools.
        ignoredProperties = unique
          (config.disko.zfs.settings.ignoredProperties ++ cryptoProperties);
        datasets = listToAttrs (map datasetSpec inPool);
      };

      # For each dataset, create it if missing, and for encryption roots, set
      # `keylocation` and load the key.
      #
      # The `keylocation` property is set when the dataset is created. If the
      # key file's path changes (say, because an agenix secret is renamed),
      # unlocking the dataset should use the new path rather than the old one.
      # Therefore, we re-set this property before `zfs load-key` attempts to
      # unlock the dataset.
      #
      # We do *not* create or set the keylocation for externally-unlocked
      # encryption roots (configured with `encryption.external`). Since we do
      # not know where to get the key material for such datasets, we can only
      # create them unencrypted, which would be wrong. Similarly, messing with
      # their `keylocation` would break whatever does unlock it. Instead, we
      # just check that any such datasets already exist and have their keys
      # loaded.
      #
      # Datasets are created `-u` (unmounted), so that the first time we mount
      # the dataset then always goes through the mount step below. This is so we
      # can `chattr -i`s the underlay directory before mounting. Running a
      # normal `zfs create` without `-u` would automatically mount the dataset,
      # preventing us from making the underlay immutable.
      #
      # The pool root (depth 1) is excluded: it always exists (the pool is
      # imported before this runs) and is reconciled by disko-zfs like any
      # other declared dataset.
      #
      createDatasets = concatMapStringsSep "\n"
        (d:
          let
            name = escapeShellArg d.name;
            # Lazy: only forced in the internally-keyed encrypted branch, where
            # `d.encryption` (and its `keyFile`) is known non-null.
            keyLoc = escapeShellArg "file://${d.encryption.keyFile}";
          in
          if d.encryption != null && d.encryption.external then ''
            if ! zfs list -H -o name ${name} >/dev/null 2>&1; then
              echo "<3>externally-unlocked encryption root ${d.name} does not exist; refusing to create it (this module has no key material for it)" >&2
              exit 1
            fi
            if [ "$(zfs get -H -o value keystatus ${name})" != available ]; then
              echo "<3>key for externally-unlocked encryption root ${d.name} is not loaded (its external unlock mechanism has not run?)" >&2
              exit 1
            fi
          '' else if d.encryption != null then ''
            if [ ! -e ${escapeShellArg d.encryption.keyFile} ]; then
              echo "<3>key file ${d.encryption.keyFile} for ${d.name} is missing (is agenix ready?)" >&2
              exit 1
            fi
            if ! zfs list -H -o name ${name} >/dev/null 2>&1; then
              echo "<5>creating encryption root ${d.name}"
              zfs create -u \
                -o encryption=${escapeShellArg d.encryption.algorithm} \
                -o keyformat=${escapeShellArg d.encryption.keyFormat} \
                -o keylocation=${keyLoc} \
                ${propArgs d} ${name}
              echo ${name} >> "$RUNTIME_DIRECTORY/created-datasets"
            fi
            if [ "$(zfs get -H -o value keylocation ${name})" != ${keyLoc} ]; then
              echo "<5>updating keylocation for ${d.name}"
              zfs set keylocation=${keyLoc} ${name}
            fi
            if [ "$(zfs get -H -o value keystatus ${name})" != available ]; then
              echo "<6>loading key for ${d.name}"
              zfs load-key ${name}
            fi
          '' else ''
            if ! zfs list -H -o name ${name} >/dev/null 2>&1; then
              echo "<5>creating dataset ${d.name}"
              zfs create -u ${propArgs d} ${name}
              echo ${name} >> "$RUNTIME_DIRECTORY/created-datasets"
            fi
          '')
        (filter (d: depth d.name > 1) parentFirst);

      # Before each mount, we make the underlay directory immutable (`chattr
      # +i`), to protect against files at that path from being written while the
      # dataset is unmounted, which would break the mount. Not every filesystem
      # supports this flag, so this is a best-effort attempt. If we can't
      # chattr the underlay, we just log a warning.
      mountDatasets = concatMapStringsSep "\n"
        (d:
          let
            name = escapeShellArg d.name;
            mountpoint = escapeShellArg d.properties.mountpoint;
          in
          ''
            if [ "$(zfs get -H -o value mounted ${name})" != yes ]; then
              mkdir -p ${mountpoint}
              chattr +i ${mountpoint} \
                || echo "<4>could not set +i on underlay of ${mountpoint}; writes while unmounted will not be blocked" >&2
              echo "<6>mounting ${d.name} at ${mountpoint}"
              zfs mount ${name}
            fi
          '')
        (mountable inPool);

      # Snapshot every declared dataset's effective mountpoint into
      # old-mountpoints, after creation (so every declared dataset exists; a
      # dataset created this run is born with its declared mountpoint and so
      # never looks moved) but before disko-zfs reconciles properties.
      # cleanupOldMountpoints (below) uses the snapshot to find underlay
      # directories orphaned by a mountpoint change.
      # Unrolled per dataset (not a shell loop over a generated list:
      # shellcheck rejects a one-iteration `for` (SC2043) when a pool declares
      # a single dataset), grouped into one redirect (SC2129), which also
      # truncates the file per run.
      captureMountpoints = ''
        {
      '' + concatMapStringsSep "\n"
        (d: ''
          printf '%s\t%s\n' ${escapeShellArg d.name} \
            "$(zfs get -H -o value mountpoint ${escapeShellArg d.name})"
        '')
        inPool + ''
        } > "$RUNTIME_DIRECTORY/old-mountpoints"
      '';

      # When a declared mountpoint changes, `zfs set mountpoint=` (run by
      # disko-zfs during reconciliation) remounts the dataset at the new path
      # and leaves the old underlay directory behind --- immutable, because the
      # mount step chattr +i'd it, so a plain `rmdir` cannot remove it and
      # orphans accumulate. Remove an old underlay only when all of these hold:
      # the recorded pre-reconcile mountpoint is a real path (not
      # none/legacy/-, and never `/` itself), it differs from the dataset's
      # *current* mountpoint (which also makes re-runs no-ops), the directory
      # still exists, and nothing is mounted there (a mountpoint swap can hand
      # the old path to another dataset). Removal is `chattr -i` (best-effort,
      # mirroring the +i in the mount step) plus `rmdir`, never `rm -rf`: a
      # non-empty directory means something wrote there while the dataset was
      # unmounted, and deleting it silently would be data loss, so it is logged
      # and left for a human. If a run dies between reconciliation and this
      # step the orphan is not retried (old == current on the next run); the
      # header documents manual removal.
      cleanupOldMountpoints = ''
        while IFS=$'\t' read -r ds old_mp; do
          case "$old_mp" in
            /?*) ;;
            *) continue ;;
          esac
          new_mp="$(zfs get -H -o value mountpoint "$ds")"
          if [ "$new_mp" = "$old_mp" ] || [ ! -d "$old_mp" ]; then
            continue
          fi
          if mountpoint -q "$old_mp"; then
            echo "<6>not removing old mountpoint $old_mp of $ds: something is mounted there"
            continue
          fi
          chattr -i "$old_mp" 2>/dev/null || true
          if err="$(rmdir "$old_mp" 2>&1)"; then
            echo "<5>removed orphaned mountpoint directory $old_mp ($ds moved to $new_mp)"
          else
            echo "<4>could not remove old mountpoint $old_mp of $ds: $err; inspect and remove by hand" >&2
          fi
        done < "$RUNTIME_DIRECTORY/old-mountpoints"
      '';

      # Declared ownership is ordinary POSIX metadata on the dataset's root
      # directory, applied if this run created the dataset (tracked in
      # created-datasets). This is not reconciled after creating the dataset so
      # that later ownership changes are not clobbered on boot
      #
      # This must run after mounting the dataset, since the mountpoint must
      # exist before we can chown it.
      applyOwnership = concatMapStringsSep "\n"
        (d:
          let
            name = escapeShellArg d.name;
            mountpoint = escapeShellArg d.properties.mountpoint;
            chownArg =
              if d.owner != null then
                (if d.group != null then "${d.owner}:${d.group}" else d.owner)
              else ":${d.group}";
          in
          ''
            if grep -qxF ${name} "$RUNTIME_DIRECTORY/created-datasets"; then
              echo "<5>applying declared ownership to ${d.name} (${d.properties.mountpoint})"
              ${optionalString (d.owner != null || d.group != null)
                "chown ${escapeShellArg chownArg} ${mountpoint}"}
              ${optionalString (d.mode != null)
                "chmod ${escapeShellArg d.mode} ${mountpoint}"}
            fi
          '')
        (filter (d: d.owner != null || d.group != null || d.mode != null) inPool);

      runner = with pkgs; writeShellApplication {
        name = "zfs-datasets-${pool}";
        runtimeInputs = [
          config.boot.zfs.package
          config.disko.zfs.package
          coreutils
          e2fsprogs # chattr, for underlay hardening
          gnugrep
          util-linux # mountpoint(1), for old-mountpoint cleanup
        ];
        text = ''
          # This file records datasets created by this run, so that step 6 can
          # set their owners. This file must be truncated now, since it persists
          # across reloads of the same activation of this service, and we do not
          # want to re-apply ownership changes every time, so that ownership may
          # be set mutably once the dataset is created.
          : > "$RUNTIME_DIRECTORY/created-datasets"

          # 1. Create every declared dataset (parent-first) that does not yet
          #    exist, and load encryption keys. This is done here, late, because
          #    the passphrase files are agenix secrets that are unavailable when
          #    the early disko-zfs service runs. Creating the datasets ourselves
          #    (rather than letting disko-zfs do it) is what guarantees an
          #    encryption root is never accidentally created unencrypted.
          ${createDatasets}

          # 2. Record every declared dataset's pre-reconcile mountpoint, so
          #    step 5 can clean up underlay directories orphaned by a
          #    mountpoint change.
          ${captureMountpoints}

          # 3. Reconcile properties with disko-zfs. Every dataset already exists
          #    after step 1, so disko-zfs only sets/inherits properties (drift
          #    from the declared spec). We feed it a snapshot of the pool via
          #    `--file` so it neither touches nor reports on other pools, and
          #    the encryption-intrinsic properties are in `ignoredProperties`.
          zfs get all -t filesystem --json --json-int -r ${escapeShellArg pool} \
            > "$RUNTIME_DIRECTORY/actual.json"
          disko-zfs --file "$RUNTIME_DIRECTORY/actual.json" --log-level info \
            apply --spec ${spec}

          # 4. Mount datasets that declare a path mountpoint.
          ${mountDatasets}

          # 5. Remove old mountpoint underlay directories orphaned by a
          #    mountpoint change, now that every dataset is mounted at its
          #    declared path.
          ${cleanupOldMountpoints}

          # 6. Apply declared ownership to datasets created by this run.
          ${applyOwnership}
        '';
      };
    in
    runner;

  mkService = pool:
    let
      importUnit = "zfs-import-${pool}.service";
      target = "zfs-datasets-${pool}.target";
      runner = getExe (mkRunner pool);
    in
    {
      description = "Create, unlock, and mount ZFS datasets on ${pool}";
      # Layout changes are applied by `nixos-rebuild switch` by reloading the
      # service, rather than restarting it. This is important, because reloading
      # it re-runs the script *without* stopping the systemd unit, which would
      # propagate through all the units that have `Requires` dependencies on the
      # service or the target. A restart would take down any dependent services,
      # and if they, too had not changed, NixOS would not stand them back up,
      # which would be...sad. This way, if the reload fails, the `nixos-rebuild
      # switch` will report it loudly, but the target will stay active and any
      # consumers of the previous mounts stay running. This is similar to how
      # the NixOS firewall service works.
      reloadIfChanged = true;
      # `after` a nonexistent unit is harmless, since (ordering constraints
      # against units that don't exist are ignored). However, `requires` is not,
      # so the import unit is only required for pools this module actually
      # imports.
      after = [ importUnit "zfs-mount.service" ];
      requires = optional cfg.pools.${pool}.importAtBoot importUnit;
      # Binding the target to *success* of the datasets service using
      # `Requires`, ensures that consumers that depend on the target will not
      # start if the unlock or mount fails.
      requiredBy = [ target ];
      before = [ target ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "zfs-datasets-${pool}";
        ExecStart = runner;
        ExecReload = runner;
      };
    };

  # The target consumers gate on (`requires` + `after`) to guarantee the pool's
  # datasets are unlocked and mounted before they start. Only `wantedBy` (not
  # required by) multi-user.target, so a failed unlock never blocks the rest of
  # boot.
  mkTarget = pool: {
    description = "ZFS datasets on ${pool} are unlocked and mounted";
    wantedBy = [ "multi-user.target" ];
  };

  perPool = f: listToAttrs (map (p: nameValuePair "zfs-datasets-${p}" (f p)) latePools);

  # Resolve a filesystem path to the units which a consumer service that
  # requires that path to be mounted must depend on. This finds the pool
  # containing the declared dataset whose mountpoint is the longest path-prefix
  # of the given path.
  #
  # If it's a late pool, then the consumer will depend on the per-pool target
  # (`requires` + `after`, plus `after` on the oneshot itself so a start racing
  # a reload waits for it). Consumers of early pools can instead depend on
  # `zfs-mount.service`. A path which no declared dataset mounts is an eval-time
  # error, to catch typos or missing datasets.
  zfsMountDeps = serviceName: path:
    let
      p = if path == "/" then path else removeSuffix "/" path;
      # A dataset "owns" a path only if the runner will actually mount it:
      # a path `mountpoint` AND `canmount` != off. Without the canmount check, a
      # container dataset could win the prefix match and the consumer would
      # require a target that never actually mounts the path it cares about.
      owns = d:
        let
          mountpoint = d.properties.mountpoint or "none";
          canmount = (d.properties.canmount or "on");
        in
        hasPrefix "/" mountpoint && (canmount != "off")
        && (p == mountpoint || hasPrefix "${mountpoint}/" p);
      byMountpointLen = a: b:
        stringLength a.properties.mountpoint > stringLength b.properties.mountpoint;
      candidates = sort byMountpointLen (filter owns datasetList);
      d = head candidates;
      pool = poolOf d.name;
      declaredMountpoints = map (d: d.properties.mountpoint)
        (filter (d: hasPrefix "/" (d.properties.mountpoint or "none")) datasetList);
    in
    if !cfg.enable then
      throw ''
        systemd.services.${serviceName}.requiresZfsMounts is set, but
        `profiles.zfs.enable` is false on this host, so no dataset units
        exist to depend on.''
    else if candidates == [ ] then
      throw ''
        systemd.services.${serviceName}.requiresZfsMounts: no mountable
        dataset declared in `profiles.zfs.pools` owns a prefix of "${path}".
        Declared mountpoints: ${concatStringsSep ", " declaredMountpoints}''
    else if isLate d then {
      requires = [ "zfs-datasets-${pool}.target" ];
      after = [ "zfs-datasets-${pool}.target" "zfs-datasets-${pool}.service" ];
    } else {
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
    };

  encryptionSubmodule = types.submodule {
    options = {
      external = mkOption {
        type = types.bool;
        default = false;
        description = ''
          This dataset is an encryption root unlocked by something *other*
          than this module (initrd clevis/TPM, `zfs load-key` over initrd
          SSH, ...). The module then never touches its keys: it does not set
          `keylocation` (an external unlock mechanism may dispatch on the
          stored value, e.g. `prompt`), does not load keys, and **refuses to
          create the dataset if it is missing** --- with no key material,
          creation could only produce an unencrypted dataset. The key must
          already be loaded when the oneshot runs; PAM-at-login unlocking is
          therefore not supported. Mutually exclusive with {option}`keyFile`
          and {option}`keyFormat` (asserted).
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression "config.age.secrets.moonpool-system-pass.path";
        description = ''
          Path to the file containing the encryption key (such as an agenix
          secret's `.path`). Required unless {option}`external` is set. The
          dataset is created with `keylocation = file://<this path>` and
          unlocked from it at boot; if the path later changes, the stored
          `keylocation` is reconciled to follow it.

          To rotate the key itself, deploy the new file contents first, then
          run `zfs change-key <dataset>` on the host: it reads the *new* key
          from the stored `keylocation`, and the already-loaded key keeps the
          dataset available in the meantime.
        '';
      };

      keyFormat = mkOption {
        type = types.nullOr (types.enum [ "passphrase" "hex" "raw" ]);
        default = null;
        description = ''
          The `keyformat` for the encryption root. Required unless
          {option}`external` is set, and deliberately without a default: it
          must match the actual contents of {option}`keyFile`.

          `passphrase` (with an actual passphrase in the file) is recommended:
          the same passphrase can unlock the dataset on any machine (using `zfs
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
        type = propertiesSubmodule;
        default = { };
        example = { mountpoint = "/srv/media"; autoSnapshot = false; };
        description = ''
          ZFS properties to set on the dataset. Common, typo-prone properties
          have typed options (`mountpoint`, `recordsize`, `autoSnapshot`, ...);
          any other property may be set freeform under its ZFS name (e.g.
          `"org.example:my-prop" = "x"`). Do not define the same property both
          ways (asserted at evaluation time). Encryption-intrinsic properties
          (`encryption`, `keyformat`, `keylocation`, ...) are managed
          automatically from the encryption options and must not be set here.

          The configuration owns every declared local property. A property set
          with `zfs set` but absent here is inherited away at the next
          reconciliation. Declare it here or add it to
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
          Sets the group of the dataset root when it is created, as with
          {option}`owner`. The group must exist in {option}`users.groups`
          (checked at evaluation-time).
        '';
      };

      mode = mkOption {
        # Three or four octal digits. The optional leading digit supports
        # setuid, setgid, and sticky bits (setgid directories may be useful for
        # shared trees).
        type = types.nullOr (types.strMatching "[0-7]{3,4}");
        default = null;
        example = "0750";
        description = ''
          Sets the mode of the dataset root when it is created, as with
          {option}`owner`. Use `0750` or `0700` for per-user datasets. The
          default directory mode, `0755`, lets every local user read every other
          user's data despite separate encryption roots.
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
        type = propertiesSubmodule;
        default = { };
        example = { mountpoint = "none"; compression = "lz4"; };
        description = ''
          Sets ZFS properties for the pool's *root* dataset, equivalent to
          disko's `rootFsOptions`. It supports the same typed and freeform
          properties as a dataset. If this is empty while child datasets are
          declared, the root dataset is neither created nor reconciled.
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

          Likewise, declare `mountpoint` explicitly on every dataset that
          should be mounted: the mount step only sees *declared* mountpoints,
          so a dataset relying on a ZFS-inherited mountpoint is never mounted
          by the oneshot (and is invisible to `requiresZfsMounts`).
        '';
      };
    };
  };
in
{
  # Per-service sugar for the consumer discipline described in the header.
  # Same extension pattern as `systemd-confinement`: this submodule merges
  # into the stock `systemd.services.<name>` type, and derives its own
  # `requires`/`after` from the new option.
  options.systemd.services = mkOption {
    type = types.attrsOf (types.submodule ({ name, config, ... }: {
      options.requiresZfsMounts = mkOption {
        type = types.listOf (types.strMatching "/.*");
        default = [ ];
        example = [ "/srv/media" ];
        description = ''
          Paths this service needs mounted before it starts. Each path must
          live under a mountpoint declared in {option}`profiles.zfs.pools`
          (evaluation fails otherwise); the service gains `requires` and
          `after` on whatever unlocks and mounts that dataset ---
          `zfs-datasets-<pool>.target` for pools with encrypted datasets,
          `zfs-mount.service` otherwise. `requires` (not just ordering) means
          the service is not started when unlock or mount fails, instead of
          running against the empty mountpoint directory.
        '';
      };
      config = mkIf (config.requiresZfsMounts != [ ]) (
        let deps = map (zfsMountDeps name) config.requiresZfsMounts; in
        {
          requires = unique (concatMap (x: x.requires) deps);
          after = unique (concatMap (x: x.after) deps);
        }
      );
    }));
  };

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
  # systemd unit names depend on `latePools`. A top-level key (or a `mkMerge`
  # list length) that depends on an option value forces that option while the
  # module fixpoint is still being computed, which deadlocks:
  # `_module.check` -> our config -> the option -> `_module.check`.
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
            but is never mounted (no path mountpoint, or canmount=off) ---
            there is nothing to chown.'';
        }
        ++ optional (filter (n: elem n cryptoProperties) (attrNames d.properties) != [ ]) {
          assertion = false;
          message = ''
            profiles.zfs.pools: dataset "${d.name}" sets encryption-intrinsic
            properties (${concatStringsSep ", " (filter (n: elem n cryptoProperties) (attrNames d.properties))})
            in `properties`; these are managed by the `encryption` options and
            would otherwise be silently discarded.'';
        }
        ++ optional (d.conflicts != [ ]) {
          assertion = false;
          message = ''
            profiles.zfs.pools: dataset "${d.name}" defines properties both
            via a typed option and as a freeform ZFS property name: ${concatStringsSep ", " d.conflicts}.
            Use one or the other.'';
        }
        ++ optional (d.encryption != null) {
          assertion =
            if d.encryption.external
            then d.encryption.keyFile == null && d.encryption.keyFormat == null
            else d.encryption.keyFile != null && d.encryption.keyFormat != null;
          message =
            if d.encryption.external then ''
              profiles.zfs.pools: dataset "${d.name}" sets `encryption.external`
              together with `keyFile`/`keyFormat`; an externally-unlocked root
              has no module-managed key material. Set one or the other.''
            else ''
              profiles.zfs.pools: dataset "${d.name}" declares `encryption` but
              is missing `keyFile` and/or `keyFormat` (required unless
              `encryption.external` is set).'';
        })
      datasetList
    # Pools backing boot-critical filesystems are imported by the initrd;
    # adding them to `boot.zfs.extraPools` (what `importAtBoot` does) makes the
    # extra import unit try to `zfs load-key` every locked dataset in the pool
    # at boot --- interactive prompts and a failed unit on hosts with
    # login-unlocked datasets.
    ++ mapAttrsToList
      (poolName: pcfg:
        let
          bootFs = filter
            (fs:
              fs.fsType == "zfs" && fs.device != null
                && poolOf fs.device == poolName
                && utils.fsNeededForBoot fs)
            (attrValues config.fileSystems);
        in
        {
          assertion = pcfg.importAtBoot -> bootFs == [ ];
          message = ''
            profiles.zfs.pools: pool "${poolName}" backs filesystems needed for
            boot (${concatStringsSep ", " (map (fs: fs.mountPoint) bootFs)}) and
            is therefore imported from the initrd; set `importAtBoot = false`
            for it.'';
        })
      cfg.pools;

    boot.zfs.extraPools = attrNames (filterAttrs (_: p: p.importAtBoot) cfg.pools);

    # Configure disko-zfs to ignore the things we are managing in this module,
    # and not mess with other properties that it shouldn't touch.
    disko.zfs.enable = lib.mkDefault true;
    disko.zfs.settings = {
      logLevel = lib.mkDefault "info";
      # Runtime-managed properties that `disko-zfs` should never fight over,
      # plus the encryption-intrinsic properties: the early service also
      # reconciles disko-declared pools (i.e. the root pool), and an encryption
      # root's `encryption`/`keyformat` have non-user-managed sources there ---
      # "reconciling" them is impossible and logs an error on every boot.
      # NOT mkDefault: a plain user assignment would *replace* this list,
      # silently dropping the crypto ignores --- and a disko-declared
      # encryption root would then be created unencrypted by the early
      # service (crypto props get filtered from its create args). Without a
      # priority, user additions merge by concatenation instead.
      ignoredProperties =
        [ "nixos:shutdown-time" ":generation" ] ++ cryptoProperties;
      # Unencrypted pools go through the stock (early) disko-zfs service.
      #
      # The second merge entry compensates for a gap in upstream disko-zfs's
      # auto-import of `disko.devices.zpool`: it copies each dataset's
      # `options` attrset but drops the top-level disko `mountpoint`
      # attribute --- which disko sets as a LOCAL property at creation. An
      # auto-imported spec without it makes reconciliation `zfs inherit
      # mountpoint` on every such dataset (today that mostly fails-silently
      # because the datasets are busy, but that is luck, not design). Inject
      # the missing mountpoints so the spec matches what disko actually
      # created. TODO: upstream this into disko-zfs's auto-import.
      datasets = mkMerge [
        (listToAttrs (map datasetSpec earlyDatasets))
        (mkIf (config.disko or { } ? devices)
          (listToAttrs (concatLists (mapAttrsToList
            (poolName: zpool: concatLists (mapAttrsToList
              (dsName: ds:
                optional ((ds.type or "") == "zfs_fs" && (ds.mountpoint or null) != null)
                  (nameValuePair "${poolName}/${dsName}" {
                    properties.mountpoint = ds.mountpoint;
                  }))
              (removeAttrs zpool.datasets [ "__root" ])))
            (config.disko.devices.zpool or { })))))
      ];
      # Keep the early stock `disko-zfs` service away from pools this module is
      # managing via its late oneshot service, as well as from any unmanaged
      # (undeclared) pool root. It will not try to create their datasets nor
      # clobber their settings or destroy them.
      ignoredDatasets =
        concatMap (p: [ p "${p}/*" ]) latePools
        ++ filter (p: !(elem p latePools)) unmanagedRoots;
    };
    systemd.services = perPool mkService;
    systemd.targets = perPool mkTarget;
  };
}
