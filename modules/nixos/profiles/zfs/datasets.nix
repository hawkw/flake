# Declarative ZFS dataset management extending `disko-zfs` with typed dataset
# properties, management of data pools that do not block boot on failure, and
# managed dataset encryption keys (such as `agenix` secrets).
#
# == Theory of operation ==
#
# This is a wrapper around [`disko-zfs`](https://github.com/numtide/disko-zfs)
# that lets every dataset in a pool be declared in one place, and then
# configures the mechanism to manage that pool. How a pool is managed depends
# on whether the system needs it in order to boot, determined based on where its
# filesystems are mounted:
#
# * a *root pool* has at least one dataset mounted somewhere needed for boot:
#   one of the paths in nixpkgs' `utils.pathsNeededForBoot` (`/`, `/nix`,
#   `/var`, `/etc`, ...), or has `neededForBoot = true`. This is the same rule
#   nixpkgs applies to `fileSystems` entries to decide which pools should be
#   imported in the initrd.
#
#   NixOS imports root pools, and loads their encryption keys, in the initrd.
#   Datasets on root pools are reconciled by the stock `disko-zfs` service,
#   which runs early in boot.
# * every other pool is a *data pool*. Each data pool is managed by a late,
#   per-pool oneshot service (`zfs-datasets-<pool>.service`), which runs after
#   the pool is imported. This service creates missing datasets, loads keys,
#   reconciles properties with `disko-zfs`. The service also mounts any
#   zfs-mounted datasets, and systemd-mounted datasets are mounted after the
#   service succeeds  (see "Mounting datasets" for more details).
#
# === Management of Data Pools ===
#
# Booting the system does not depend on a data pool, so a data pool that cannot
# be imported and configured should not stop boot. Instead, only the services
# that depend on that pool should not start when it is in a bad state, so that
# the issue may be resolved on a booted system. A data pool can fail to import
# (a missing disk or HBA), and its encryption keys, which are not loaded in the
# initrd, can fail to load (the key file was never decrypted, the TPM refused,
# and so on).
#
# The stock `disko-zfs` service cannot provide this: it is required by
# `local-fs-pre.target` and `zfs-mount.service`, so if any pool it manages
# fails, then `local-fs.target` fails, and the system doesn't boot. Services
# which require pools managed by disko-zfs cannot depend on `zfs-mount.service`
# to ensure they are not started if the pool is unavailable, either, since it is
# only ordered after `zfs-import.target`. When a data pool fails to import,
# `zfs mount -a` still runs, has nothing to mount from that pool, and succeeds
# (spuriously).
#
# The per-pool oneshot instead runs at `multi-user.target`, and is not required
# for `local-fs.target` to succeed. It requires the import unit for the pool,
# and represents its own success as `zfs-datasets-<pool>.target`. The data
# pool's systemd mounts have `nofail` (so `local-fs.target` does not require or
# wait for for them), but do require the oneshot. Therefore, if the import unit
# or the oneshot fails, the mounts, the target, and every service that depends
# on them (see "Services which use datasets" below) do not start, but nothing
# else is affected. This way, any issues that prevent the datasets from mounting
# can be diagnosed and repaired interactively on an otherwise healthy system.
#
# === Mounting datasets ===
#
# Each dataset with a path `mountpoint` may be mounted either by systemd, by
# zfs, or by an external mechanism (such as `pam_zfs_key`). This is configured
# by the `mountedBy` option, which defaults to "systemd".
#
#   mountedBy  | root pool                         | data pool
#   -----------+-----------------------------------+-----------------------------
#   systemd    | `fileSystems` entry with          | `fileSystems` entry with
#              | `zfsutil` (from disko, if the     | `nofail` and
#              | pool uses disko); the `mountpoint`| `x-systemd.requires=` on the
#              | property is the path              | oneshot; the `mountpoint`
#              |                                   | property is `legacy`
#   zfs        | mounted by `zfs-mount.service`    | mounted by the oneshot;
#              |                                   | `canmount=noauto`
#   explicit   | not mounted at boot; `canmount=noauto` and
#              | `org.openzfs.systemd:ignore=on` (both pools)
#
# Properties implied by the various `mountedBy` options (such as `legacy`,
# `noauto`, `ignore`) are applied and reconciled through the same means as
# explicitly declared properties. Explicitly declared `canmount`/`ignore`
# properties precedence. These properties must be set to ensure that exactly one
# thing mounts each dataset, since `zfs mount -a` (in `zfs-mount.service`) will
# attempt to mount every dataset with a path `mountpoint` and `canmount=on`
# whose key is loaded, as soon as the pool is imported.
#
# ==== systemd vs zfs mounts ====
#
# `systemd` is the default because having a systemd mount unit lets consuming
# systemd units use `RequiresMountsFor=` to depend on the mountpoint. Because
# the initrd only mounts `fileSystems` entries, datasets needed for boot
# *must* be mounted by systemd.
#
# In contrast, the `zfs` mount options keep the path in the pool itself, so if
# the pool is imported on another system, running `zfs import`  plus `zfs mount`
# will mount its datasets at the configured mountpoints. This comes at the cost
# of consuming systemd units needing explicit dependencies.
#
# Finally, the `explicit`option is for datasets whose keys are not available at
# boot, such as PAM-at-login unlocking, or datasets which are mounted by hand or
# by other software.
#
# `nixos-rebuild switch` remounts a systemd-mounted dataset in place when only
# its mount options change, and restarts its mount unit (which stops any
# consuming units consumers) only when the dataset behind a path changes. ZFS
# property changes do not touch mount units at all.
#
# === Disko ===
#
# A pool's devices (disks, partitions, vdevs, pool options) may be declared with
# disko, for root and data pools alike. To do so, set the `disko` option and
# this module configure `disko.devices.zpool.<pool>` for that pool, with the
# contents of the that attrset, plus any `rootFsOptions` determined from the
# pool's `properties`. Both root pools and data pools may provide disko device
# configuration.
#
# A root pool's datasets are also written to the disko config , because
# `disko-install` must create and mount them under `/mnt` before
# `nixos-install`. disko then generates their `fileSystems` entries
# (systemd-mounted ones get disko's top-level `mountpoint`), which are imported
# into `disko-zfs`'s spec. On the other hand, a data pool's datasets are never
# passed to disko; its oneshot creates the datasets, and this module generates
# their `fileSystems` entries.
#
# Datasets of pools in `profiles.zfs.pools` must be declared here only, not in
# `disko.devices`. This is checked by an assertion to avoid misconfigurations.
#
# === Creating datasets ===
#
# `disko-zfs` cannot safely create encryption roots. ZFS encryption properties
# are read-only after creation, and therefore must be ignored when dataset
# properties are reconciled. Unfortunately, ignoring them from reconciliation
# also omits them from `disko-zfs`'s `zfs create` invocation when the dataset
# does not exist. That means that an encryption root that does not yet exist
# would be created unencrypted. The oneshot creates a data pool's datasets
# itself, and configures `disko-zfs` to ignore encryption-related properties.
#
# Each data pool is managed by exactly one service, its oneshot. Splitting a
# pool between the early stock `disko-zfs` service and the oneshot would be
# unsafe, because when `disko-zfs` creates missing parent datasets, it does not
# set any properties. Therefore, it could create a parent without the
# properties that the other service declares for it.
#
# Root pools are unlocked in the initrd, before this module runs, so on a root
# pool this module can only manage encryption roots that something else unlocks
# (`encryption.external`, typically `boot.initrd.clevis` or a console prompt).
# Module-managed keys (`encryption.keyFile`) and declared ownership
# (`owner`/`group`/`mode`, applied by the oneshot) are therefore only supported
# on data pools; both are asserted. An external encryption root on a root pool
# is still reconciled by the early `disko-zfs` service, which would create it
# unencrypted if it were missing, so this module adds a check to that service
# which fails it instead.
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
# === Services which use data pool datasets ===
#
# A service which requires filesystems on a data pool **must** depend on what
# mounts them, with both `requires` and `after`, or else it may be started
# before the pool is imported, unlocked (if encrypted), and mounted:
#
# * for a systemd-mounted dataset, the mount unit for that dataset
#   (`RequiresMountsFor=`);
# * for a ZFS-mounted dataset, the oneshot service for that pool
#   (`zfs-datasets-<pool>.target`).
#
# Setting `requires` is necessary to prevent the service from starting when
# bringing up the pool fails. `after` without `requires` only establishes
# *ordering*, so the service would still run after a failed oneshot and write
# into the empty mountpoint directory on the root filesystem. A failed data
# pool does not block the rest of boot.
#
# Services may declare these dependencies using the `requiresZfsMounts` setting
# from this module, like:
#
# ```
# systemd.services.<name>.requiresZfsMounts = [ "/srv/path" ];
# ```
#
# Each path is resolved to the declared dataset with the longest matching
# mountpoint prefix, and adds the right dependency for that dataset (including
# `zfs-mount.service` for ZFS-mounted datasets on root pools). If the path is
# not part of a dataset managed by this module, or is on an explicitly mounted
# dataset, this will produce an evaluation error.
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
# Before mounting a ZFS-mounted dataset on a data pool, the runner makes the
# mountpoint underlay directory immutable (`chattr +i`). While the dataset is
# unmounted, writes to its mountpoint fail with `EPERM`, even for root. Without
# this, such writes would succeed and then be silently hidden once the dataset
# is mounted over them (ZFS's `overlay` property, on by default on Linux, lets
# it mount over a non-empty directory). When the dataset is mounted, the
# immutable directory is overlayed by the mounted filesystem. Systemd-mounted
# datasets rely on consumers' dependencies instead.
#
# There is one important operational consideration that results from this: if a
# dataset's mountpoint *changes*, this module will attempt to remove the old
# immutable underlay directory. Typically, this occurs automatically, but on the
# off chance that the underlay directory is non-empty, this module will refuse
# to remove it, since, well, you might still want whatever's in there. A
# non-empty underlay means something wrote there before the directory was made
# immutable, or a mountpoint was *accidentally* set to a non-empty directory. If
# this *does* occur, note that the underlay directory will still be immutable,
# so you will have to manually run `chattr -i <path>` to make it mutable again.
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
    attrNames;

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

  # The ZFS properties determined by how a mounted dataset is mounted (see
  # "Mounting datasets" in the header). Explicitly declared properties take
  # precedence, except that a systemd-mounted dataset on a data pool must always
  # have `mountpoint=legacy`, to ensure that it is only mounted by systemd.
  mountProperties = { rootPool, mounted, mountedBy }: props:
    if !mounted then props
    else if mountedBy == "systemd" then
      (if rootPool then props else props // { mountpoint = "legacy"; })
    else if mountedBy == "zfs" then
      (if rootPool then props else { canmount = "noauto"; } // props)
    else { canmount = "noauto"; "org.openzfs.systemd:ignore" = "on"; } // props;

  # Given an attrset declaring a pool (in `pools.<name>.{properties,datasets}`),
  # flattens it into records containing the following:
  #
  # - `name`: the name of the dataset or pool, and `relname`, its name relative
  #   to the pool (or `null` for the pool root),
  # - `rootPool`: whether the pool is a root pool (see `isRootPool`), and
  #   `diskoPool`: whether its devices are declared with disko (it sets
  #   `disko`),
  # - `mountpoint`: the *declared* `mountpoint` property (a path, `none`,
  #   `legacy`, or `null` if undeclared), and `mounted`: whether it is a path
  #   and the declared `canmount` property is not `off`,
  # - `properties`: the ZFS properties to apply. This includes both the
  #   declared ones and those implied by `mountedBy` (see `mountProperties`).
  #   For a systemd-mounted dataset on a data pool, `properties.mountpoint` is
  #   therefore `legacy`, and the path is only in `mountpoint`.
  # - `conflicts`: any conflicts between typed and untyped properties, used to
  #   output evaluation errors if non-empty,
  # - `encryption`, `owner`, `group`, `mode`, `mountedBy`, `neededForBoot`,
  #   and `disko`: the dataset options of the same names.
  #
  # The pool root is only included here if pool-level defaults are declared. It
  # is never mounted (asserted).
  poolDatasets = pool: pcfg:
    let
      diskoPool = pcfg.disko != null;
      rootPool = isRootPool pool;
      record = relname: props: opts:
        let
          inherit (props) mountpoint;
          mounted = mountpoint != null && hasPrefix "/" mountpoint
            && props.canmount != "off";
        in
        opts // {
          name = if relname == null then pool else "${pool}/${relname}";
          inherit relname rootPool diskoPool mountpoint mounted;
          properties = mountProperties { inherit rootPool mounted; inherit (opts) mountedBy; }
            (toZfsProps props);
          conflicts = propertyConflicts props;
        };
    in
    optional (toZfsProps pcfg.properties != { })
      (record null pcfg.properties {
        encryption = null;
        owner = null;
        group = null;
        mode = null;
        mountedBy = "zfs";
        neededForBoot = false;
        disko = { };
      })
    ++ mapAttrsToList
      (relname: d: record relname d.properties {
        inherit (d) encryption owner group mode mountedBy neededForBoot disko;
      })
      pcfg.datasets;

  datasetList = concatLists (mapAttrsToList poolDatasets cfg.pools);

  poolOf = name: head (splitString "/" name);
  depth = name: length (splitString "/" name);

  # A pool is a *root pool* if any dataset declared on it is mounted somewhere
  # needed for boot, either at one of nixpkgs' `utils.pathsNeededForBoot` (`/`,
  # `/nix`, `/var`, ...), or with `neededForBoot = true`. This is the same way
  # that nixpkgs' `utils.fsNeededForBoot` uses to determine which should be
  # imported in the initrd (see `rootPools` in
  # `nixos/modules/tasks/filesystems/zfs.nix`). This module determine this
  # separately, based on the declared datasets on the pool, so that we do not
  # need to depend on the `fileSystems` configuration, because we will generate
  # `fileSystems` entries.
  isBootMount = d:
    let inherit (d.properties) mountpoint canmount; in
    mountpoint != null && hasPrefix "/" mountpoint && canmount != "off"
    && (d.neededForBoot || elem mountpoint utils.pathsNeededForBoot);
  isRootPool = pool: lib.any isBootMount (lib.attrValues cfg.pools.${pool}.datasets);

  # The pools nixpkgs imports in the initrd, computed from `fileSystems` as
  # nixpkgs does. Only used to check that `isRootPool` agrees.
  nixpkgsBootFileSystems = filter
    (fs: fs.fsType == "zfs" && fs.device != null && utils.fsNeededForBoot fs)
    config.system.build.fileSystems;

  # Data pools with at least one declared dataset, or declared pool-root
  # properties (if it doesn't declare anything, it doesn't need to be managed).
  # Each of these pools will be managed by their own late oneshots.
  dataPools = filter (p: !isRootPool p) (unique (map (d: poolOf d.name) datasetList));

  rootPoolDatasets = filter (d: d.rootPool) datasetList;

  # External encryption roots on root pools. These pools are reconciled by the
  # `disko-zfs` service, and it would create these roots *unencrypted* if they
  # are missing; see the guard on that service below.
  rootPoolExternalEncryptionRoots = filter (d: d.encryption != null && d.encryption.external)
    rootPoolDatasets;

  # Root pool datasets on disko pools also generate disko config, so that disko
  # can create and mount them at install time. This means that disko will then
  # generates their `fileSystems` entries. For all other systemd-mounted
  # datasets, this module generates their `fileSystems` entries.
  inDisko = d: d.diskoPool && d.rootPool && d.relname != null;
  systemdMounts = filter (d: d.mounted && d.mountedBy == "systemd") datasetList;

  # Generates a Disko `zfs_fs` config for a dataset. disko creates it with these
  # options at install time (including the encryption properties, which disko,
  # unlike `disko-zfs`, passes to `zfs create`), they are reconciled by
  # `disko-zfs` reconciles them afterwards.
  toDiskoDataset = d:
    let

      # Only systemd-mounted datasets get disko's top-level `mountpoint`, which
      # is what makes disko generate a `fileSystems` entry. Non-systemd-mounted
      # datasets get only the `mountpoint` property, in `options`.
      diskoMountpoint = lib.optionalAttrs
        (d.mounted && d.mountedBy == "systemd")
        {
          inherit (d) mountpoint;
        };
    in
    d.disko // {
      type = "zfs_fs";
      options = mapAttrs (_: toString) (d.properties
      // lib.optionalAttrs (d.encryption != null) {
        encryption = d.encryption.algorithm;
        keyformat = d.encryption.keyFormat;
        keylocation = "prompt";
      });
    } // diskoMountpoint;


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

  # Datasets with `mountedBy = "zfs"` are mounted by the per-pool runner
  # oneshot. These are sorted by the path depth of the *mountpoint*, not the
  # depth of the dataset, to ensure that they are mounted in order by
  # mountpoint rather than by how deeply nested the datasets are.
  mountable = ds:
    let
      mountDepth = d: length (splitString "/" d.mountpoint);
    in
    sort (a: b: mountDepth a < mountDepth b)
      (filter (d: d.mounted && d.mountedBy == "zfs") ds);

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
            mountpoint = escapeShellArg d.mountpoint;
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
            setOwnership = ''
              ${optionalString (d.owner != null || d.group != null)
                ''chown ${escapeShellArg chownArg} "$dir"''}
              ${optionalString (d.mode != null)
                ''chmod ${escapeShellArg d.mode} "$dir"''}
            '';
          in
          ''
            if grep -qxF ${name} "$RUNTIME_DIRECTORY/created-datasets"; then
              echo "<5>applying declared ownership to ${d.name}"
          '' + (if d.mountedBy == "systemd" then ''
            dir="$RUNTIME_DIRECTORY/mnt"
            mkdir -p "$dir"
            mount.zfs ${name} "$dir"
            if ! { ${setOwnership} }; then
              umount "$dir"
              exit 1
            fi
            umount "$dir"
          '' else ''
            dir=${escapeShellArg d.mountpoint}
            ${setOwnership}
          '') + ''
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
          #    exist, and load encryption keys. This is done here, late, so
          #    that a missing or undecryptable key file fails this unit (and
          #    therefore its target) rather than stopping the system from
          #    booting. Creating the datasets ourselves (rather than letting
          #    disko-zfs do it) guarantees that an encryption root is never
          #    accidentally created unencrypted.
          ${createDatasets}

          # 2. Record every declared dataset's pre-reconcile mountpoint, so
          #    step 5 can clean up underlay directories orphaned by a
          #    mountpoint change.
          ${captureMountpoints}

          # 3. Reconcile properties with disko-zfs. Every dataset already exists
          #    after step 1, so disko-zfs only sets and inherits properties. We
          #    run it on a snapshot of the pool via `--file`, so it won't see
          #    any other pools, and the encryption-intrinsic properties are in
          #    `ignoredProperties`.
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
      #
      # In its `systemd.sysusers`/`services.userborn` mode, `agenix` installs
      # secrets from `agenix-install-secrets.service`, which is wanted by, but
      # not ordered before, `sysinit.target`, so without this ordering the
      # runner could look for key files before they exist. In its default
      # activation-script mode, secrets are installed before any unit starts
      # and that unit does not exist, so we can depend on it unconditionally.
      after = [ importUnit "zfs-mount.service" "agenix-install-secrets.service" ];
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

  # Generates the systemd target that services can depend on (`requires` +
  # `after`) to guarantee the pool's datasets are unlocked and mounted before
  # they start. This target is only `wantedBy` (not required by)
  # multi-user.target, so a failed data pool never blocks the rest of boot.
  mkTarget = pool: {
    description = "ZFS datasets on ${pool} are unlocked and mounted";
    wantedBy = [ "multi-user.target" ];
  };

  perPool = f: listToAttrs (map (p: nameValuePair "zfs-datasets-${p}" (f p)) dataPools);

  # Resolve a filesystem path to the dependencies of a consumer service that
  # requires that path to be mounted. This finds the declared dataset whose
  # mountpoint is the longest path-prefix of the given path, and returns
  # `requires`/`after` units and `mountsFor` paths for `RequiresMountsFor=`.
  #
  # If it's on a data pool, then the consumer will depend on the per-pool target
  # (`requires` + `after`, plus `after` on the oneshot itself so a start racing
  # a reload waits for it). Consumers of root pool datasets instead depend on
  # `zfs-mount.service`; boot itself depends on root pools, so there is no
  # partial failure to hold them back from. A path which no declared dataset
  # mounts is an eval-time error, to catch typos or missing datasets.
  zfsMountDeps = serviceName: path:
    let
      p = if path == "/" then path else removeSuffix "/" path;
      # A dataset "owns" a path only if it is actually mounted: a path
      # `mountpoint` AND `canmount` != off. Without the canmount check, a
      # container dataset could win the prefix match, and the consumer would
      # depend on something that never mounts the path it cares about.
      owns = d: d.mounted && (p == d.mountpoint || hasPrefix "${d.mountpoint}/" p);
      byMountpointLen = a: b: stringLength a.mountpoint > stringLength b.mountpoint;
      candidates = sort byMountpointLen (filter owns datasetList);
      d = head candidates;
      pool = poolOf d.name;
      declaredMountpoints = map (d: d.mountpoint) (filter (d: d.mounted) datasetList);
      none = { requires = [ ]; after = [ ]; mountsFor = [ ]; };
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
    else if d.mountedBy == "explicit" then
      throw ''
        systemd.services.${serviceName}.requiresZfsMounts: "${path}" is on
        dataset "${d.name}", which has `mountedBy = "explicit"` and is not 
        automatically mounted by this module. There is nothing for the service
        to depend on.''
    else if d.mountedBy == "systemd" then none // { mountsFor = [ p ]; }
    else if !d.rootPool then none // {
      requires = [ "zfs-datasets-${pool}.target" ];
      after = [ "zfs-datasets-${pool}.target" "zfs-datasets-${pool}.service" ];
    } else none // {
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
          creation could only produce an unencrypted dataset. On a data pool,
          the key must already be loaded when the pool's oneshot runs, so
          PAM-at-login unlocking is not supported.

          On a root pool, `external` is the only supported kind of encryption
          root. If the pool uses disko, disko will create it at install time
          (with `keylocation=prompt`, and the {option}`algorithm` and
          {option}`keyFormat` given here); otherwise it must be created by
          hand. After that, a missing encryption root will cause the early
          `disko-zfs` service to fail.

          This is mutually exclusive with {option}`keyFile`.
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression "config.age.secrets.moonpool-system-pass.path";
        description = ''
          Path to the file containing the encryption key (such as an agenix
          secret's `.path`). Required unless {option}`external` is set.

          This is only supported on data pools. A root pool's keys are loaded
          in the initrd, before this module runs. The dataset is created with
          `keylocation = file://<this path>` and unlocked from it at boot; if
          the path later changes, the stored `keylocation` is reconciled to
          follow it.

          To rotate the key itself, deploy the new file contents first, then
          run `zfs change-key <dataset>` on the host. This will read the *new*
          key from the stored `keylocation`, and the already-loaded key keeps
          the dataset available in the meantime.
        '';
      };

      keyFormat = mkOption {
        type = types.nullOr (types.enum [ "passphrase" "hex" "raw" ]);
        default = null;
        description = ''
          The `keyformat` for the encryption root. Required if
          {option}`keyFile`, is set, when it must match the file's actual
          contents. Also required for {option}`external` encryption roots on
          root pools that use disko, which disko will use when creating the
          encryption root.

          This option deliberately has no default, since it must match the
          actual key for the encryption root.

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
          If set, this dataset is an *encryption root*. On a data pool, the
          pool's oneshot creates it with the given key and loads that key at
          boot; on a root pool, it must be {option}`external`. Encryption does
          not change how the pool is managed: that depends only on whether the
          pool is a root pool or a data pool.

          Leave unset for unencrypted datasets and for children of an encryption
          root (children inherit their parent's key automatically).
        '';
      };

      mountedBy = mkOption {
        type = types.enum [ "systemd" "zfs" "explicit" ];
        default = "systemd";
        description = ''
          How to mount this dataset at its {option}`properties.mountpoint`, if
          that is a path (otherwise, this has no effect). See "Mounting
          datasets" in this module's header for the trade-offs.

          - `systemd`: generates a `fileSystems` entry, which creates a systemd
            mount unit. Other systemd units can depend on mount units with
            `RequiresMountsFor=`.

            On a root pool that uses disko, disko will generate the
            `fileSystems` entry. Otherwise, this module generates it.
            On a root pool, the entry uses `zfsutil` and the dataset's
            `mountpoint` property, as disko's entries do. On a data pool, it
            will set `nofail` and requires the pool's oneshot, and the dataset's
            ZFS `mountpoint` property will be set to `legacy`.
          - `zfs`: generates a ZFS  `mountpoint` property so that the dataset
             is mounted natively by ZFS.

             The dataset will be mounted by `zfs-mount.service` on a root pool,
             or by the pool's oneshot on a data pool (in which case, the dataset
             also gets `canmount=noauto`, so that `zfs-mount.service` will
             ignore it).
          - `explicit`: not mounted at boot (for PAM-at-login unlocking,
            or mounting by hand). The dataset gets `canmount=noauto` and
            `org.openzfs.systemd:ignore=on`, unless it declares them explicitly.
            Note that `canmount` is not inherited.

          Datasets mounted somewhere needed for boot (see
          {option}`neededForBoot`) must use `systemd` (asserted).
        '';
      };

      neededForBoot = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this dataset is needed for boot, in addition to the paths
          NixOS always considers needed for boot (`/`, `/nix`, `/var`, `/etc`,
          and so on, see `utils.pathsNeededForBoot` in nixpkgs). This is passed
          to the dataset's `fileSystems` entry. A pool with any dataset needed
          for boot is a *root pool*, and will be imported by NixOS in the
          initrd.
        '';
      };

      disko = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        example = { mountOptions = [ "rw" ]; };
        description = ''
          Passed through to this dataset's disko `zfs_fs` definition (e.g.
          `mountOptions`, `postCreateHook`). Only allowed on root pools that
          set the pool's `disko` option, since only their datasets are passed
          to disko. Using this on other pools is an eval-time error.

          This module sets `type`, `options`, and `mountpoint` itself, so any
          values given for those here are overridden.
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

          Ownership is applied by a data pool's oneshot, so it is only supported
          on data pools (asserted). Configuring owner, group, or mode for a root
          pool is an evaluation-time error.
        '';
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "users";
        description = ''
          Sets the group of the dataset root when it is created, as with
          {option}`owner`. The group must exist in {option}`users.groups`
          (checked at evaluation-time). Configuring owner, group, or mode for a
          root pool is an evaluation-time error.
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

          Configuring owner, group, or mode for a root pool is an
          evaluation-time error.
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
          Whether to import this data pool at boot (adds it to
          {option}`boot.zfs.extraPools`). If this is `false`, the pool must be
          imported some other way before its oneshot runs. Root pools are
          always imported by the initrd, so setting this to `false` for one is
          an evaluation error.
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
          Paths this service needs mounted before it starts.

          Each path must be under a mountpoint declared in
          {option}`profiles.zfs.pools`; paths not on mountpoints managed by this
          module result in an evaluation error.

          Adding a path to {option}`requiresZfsMounts` for a service will add
          `requires` and `after` on whatever mounts that path to the service.
          For data pools, this is `zfs-datasets-<pool>.target`; for root pools,
          it is `zfs-mount.service`. Setting `requires` in addition to `after`
          ensures that the service is not started when importing, unlocking, or
          mounting a data pool fails, instead of running with the empty
          mountpoint directory.
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
  # systemd unit names depend on `dataPools` (and therefore, on `fileSystems`).
  # A top-level key (or a `mkMerge` list) that depends on an option value
  # would force that option while the module fixpoint is still being computed,
  # which would deadlock, because `_module.check` depends on our config, which
  # depends on the option, which in turn would depend on `_module.check`.
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
        ++ optional ((d.owner != null || d.group != null || d.mode != null) && !inDataPool d) {
          assertion = false;
          message = ''
            profiles.zfs.pools: dataset "${d.name}" declares a POSIX owner,
            group, or mode, but ${describeRootPool (poolOf d.name)}.

            Permissions are applied by a data pool's oneshot, which root pools
            do not have; use `systemd.tmpfiles` rules instead.'';
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
        }
        ++ optional (d.encryption != null && !d.encryption.external && !inDataPool d) {
          assertion = false;
          message = ''
            profiles.zfs.pools: dataset "${d.name}" uses a key file managed by
            this module (`encryption.keyFile`), but
            ${describeRootPool (poolOf d.name)}. Keys for root pools are loaded
            in the initrd, before this module runs.

            Instead, unlock it in the initrd (such as by using
            `boot.initrd.clevis`, or a prompt via
            `boot.zfs.requestEncryptionCredentials`) and set
            `encryption.external = true`.'';
        })
      datasetList
    # nixpkgs creates stage-2 import units only for data pools; root pools are
    # imported by the initrd no matter what `boot.zfs.extraPools` says, so
    # `importAtBoot = false` on one would be incorrect.
    ++ mapAttrsToList
      (poolName: pcfg: {
        assertion = isRootPool poolName -> pcfg.importAtBoot;
        message = ''
          profiles.zfs.pools: pool ${describeRootPool poolName}, so it will always
          be imported by the initrd. Therefore, `importAtBoot = false` has no
          effect.'';
      })
      cfg.pools;

    boot.zfs.extraPools = filter (p: !isRootPool p && cfg.pools.${p}.importAtBoot)
      (attrNames cfg.pools);

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
      # Root pools are reconciled by the stock (early) disko-zfs service.
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
        (listToAttrs (map datasetSpec rootPoolDatasets))
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
      # Keep the early stock `disko-zfs` service away from data pools, which
      # their own oneshots manage, as well as from any unmanaged (undeclared)
      # pool root. It will not try to create their datasets nor clobber their
      # settings or destroy them.
      ignoredDatasets =
        concatMap (p: [ p "${p}/*" ]) dataPools
        ++ filter (p: !(elem p dataPools)) unmanagedRoots;
    };
    systemd.services = mkMerge [
      (perPool mkService)
      # The early `disko-zfs` service would create a missing external encryption
      # root on a root pool *unencrypted* (see the module level comments).
      #
      # This is almost certainly not the intended behavior, so fail, instead.
      # This, in turn, fails `local-fs.target`, which is the best thing we could
      # do under these circumstances. A root pool with a missing declared
      # encryption root is not the system that was configured, so this
      # configuration cannot boot.
      (mkIf (config.disko.zfs.enable && rootPoolExternalEncryptionRoots != [ ]) {
        disko-zfs.preStart = concatMapStringsSep "\n"
          (d: ''
            if ! ${config.boot.zfs.package}/bin/zfs list -H -o name ${escapeShellArg d.name} >/dev/null 2>&1; then
              echo "<3>external encryption root ${d.name} does not exist. Refusing to let disko-zfs create it unencrypted" >&2
              exit 1
            fi
          '')
          rootPoolExternalEncryptionRoots;
      })
    ];
    systemd.targets = perPool mkTarget;
  };
}
