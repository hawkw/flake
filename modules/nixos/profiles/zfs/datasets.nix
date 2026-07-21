# Declarative ZFS dataset management (`profiles.zfs.pools`), including datasets
# encrypted with agenix-provided keys.
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
# * pools containing any encrypted dataset are managed by a late, per-pool
#   oneshot service (`zfs-datasets-<pool>.service`), which runs after the pool
#   is imported. This service uses `disko-zfs` to create missing datasets and
#   reconcile properties, loads keys, and mounts the datasets.
#
# The separate oneshot service is necessary because the encryption keys are
# `agenix` secrets. `agenix` installs secrets in an activation script, so there
# is no unit an early service could order itself after. Nothing that runs before
# `local-fs-pre.target` is guaranteed to see the key files decrypted by agenix,
# so the stock `disko-zfs` service would run before the pool can be unlocked.
# The oneshot runs at multi-user instead, and fails loudly if a key file is
# missing.
#
# `disko-zfs`'s stock service also cannot create encryption roots safely. ZFS
# encryption properties are read-only after creation, so reconciliation must
# ignore them, but ignoring them also ignores them when `disko-zfs` runs `zfs
# create`, so a missing encryption root would come up unencrypted. Whoops! The
# oneshot service works around this by creating encryption roots itself and
# configuring `disko-zfs` to ignore encryption-related properties.
#
# If a pool contains *any* encrypted datasets, that whole pool is managed by the
# oneshot, so that it can be reconciled by a single `disko-zfs` invocation.
# Splitting a pool between the early stock `disko-zfs` service and the oneshot
# runs afoul of `disko-zfs`'s `expand_sub_datasets`, which creates a dataset's
# parents if they don't already exist (with no properties), and would therefore
# clobber the intended properties of those datasets.
#
# Consumers of an encrypted pool MUST declare both `requires` and `after` on
# `zfs-datasets-<pool>.target`. `requires` is necessary to ensure that the
# service does not start if the unlock fails. If only `after` is set, the unit
# will run after the oneshot regardless of whether it succeeds or fails, and
# would write into the empty mountpoint directory on the root filesystem. A
# failed unlock never blocks the rest of boot.
#
# The easiest way to declare a dependency on a dataset managed by this module is
# `systemd.services.<name>.requiresZfsMounts = [ "/srv/path" ]`, which is also
# declared here. Each path in the list of `requiresZfsMounts` is resolved to the
# declared dataset whose mountpoint is its longest prefix, and the right
# `requires`/`after` configurations are added to the service's config
# automatically. Paths which are not managed by this module produce an error
# when evaluated.
#
#  === Operational consequences of the design ===
#
# This module's configuration owns every local property of a declared dataset.
# Just like with standard `disko-zfs`, reconciliation reverts (`zfs inherit`)
# anything set by hand and not declared here.
#
# Therefore, all properties must either be declared here or added to
# `disko.zfs.settings.ignoredProperties`.
#
# Dataset changes are applied by `nixos-rebuild switch` as a unit *reload* (see
# `reloadIfChanged` in `mkService`), so consumers stay up while the datasets are
# reconciled. One race is possible, as a service added in the same switch as a
# dataset it consumes can  before the reload has created that dataset. Consumers
# declared via `requiresZfsMounts` are ordered after the oneshot and wait for
# the reload, so this issue does not apply to them. On the other hand, a
# hand-written `requires`/`after` on only the target does not, and such a service
# may need one `systemctl start` after the switch.
#
# Mountpoint underlay directories are made immutable (`chattr +i`) before each
# mount. This ensures that while a dataset is unmounted, writes to its
# mountpoint path fail with EPERM (even for root) instead of silently landing on
# the parent filesystem and then blocking the next mount. The flag lives on the
# underlay inode, so it is invisible while the dataset is mounted. The one
# downside of this is that but it also means an abandoned mountpoint directory
# cannot be removed, even by root, until the flag is cleared. If this occurs,
# unset the immutable flag before removing the directory, using
# `chattr -i <dir>`
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkOption mkIf types mapAttrs mapAttrsToList filter elem map head splitString
    unique sort length concatMap concatLists concatMapStringsSep concatStringsSep
    escapeShellArg listToAttrs nameValuePair getExe hasPrefix removeAttrs
    removeSuffix stringLength optional optionalString filterAttrs attrNames;

  cfg = config.profiles.zfs;

  # Properties intrinsic to encryption, which `disko-zfs` reconciliation must
  # never touch:
  # * `encryption`, `keyformat`, `encryptionroot`, and `keystatus` are
  #   read-only after they are set, so reconciling them errors,
  # * `pbkdf2iters` and `pbkdf2salt` are set at key-load time, so inheriting
  #   them away would break things,
  # * `keylocation` is managed by this module, but not by disko-zfs
  cryptoProperties = [
    "encryption"
    "keyformat"
    "keylocation"
    "keystatus"
    "encryptionroot"
    "pbkdf2iters"
    "pbkdf2salt"
  ];

  # == Typed properties ==
  #
  # `properties` is a freeform attrset (RFC 42 style), plus typed options for
  # the properties that are commonly used and dangerous to spell freehand. The
  # danger of typos or misspellings is worse for ZFS *user* properties than for
  # built-in ones: a typoed native property name fails loudly when `zfs create`
  # or `zfs set` is run, but a typoed *user* property name (anything with a `:`,
  # e.g. `com.sun:autosnapshot` for `com.sun:auto-snapshot`) is valid as far as
  # ZFS is concerned and gets set, even if it's misspelt. Whatever other
  # software consumes that property will just never see it, which sucks. Typed
  # properties also encode each property's value spelling (`atime` wants on/off,
  # `com.sun:auto-snapshot` wants true/false), so nobody has to remember which
  # is which.
  #
  # Typed properties default to `null`, meaning that they are not managed by
  # this module. If this module manages a property, it is reconciled by
  # disko-zfs, so a non-null default would silently take ownership of that
  # property on every dataset. Anything without a typed option passes through
  # freeform, verbatim, under its ZFS name.
  onOff = b: if b then "on" else "off";
  trueFalse = b: if b then "true" else "false";
  sizeType = types.either types.ints.unsigned
    (types.strMatching "[0-9]+(\\.[0-9]+)?[KMGTPkmgtp]?");
  typedProperties = {
    mountpoint = {
      property = "mountpoint";
      render = v: v;
      type = types.either (types.enum [ "none" "legacy" ]) (types.strMatching "/.*");
      description = ''
        Where the dataset is mounted: an absolute path, `none`, or `legacy`.
      '';
    };
    canmount = {
      property = "canmount";
      render = v: v;
      type = types.enum [ "on" "off" "noauto" ];
      description = "Whether the dataset can be mounted.";
    };
    recordsize = {
      property = "recordsize";
      render = toString;
      type = sizeType;
      description = ''
        Suggested block size cap for files in this dataset (e.g. `"1M"`,
        `"128K"`). Files smaller than this are stored as a single block of
        roughly the file's size.
      '';
    };
    specialSmallBlocks = {
      property = "special_small_blocks";
      render = toString;
      type = sizeType;
      description = ''
        Blocks at or below this size are allocated on the pool's special vdev
        (`0` disables). Must be strictly less than the recordsize, or *all*
        data is routed to the special vdev.
      '';
    };
    quota = {
      property = "quota";
      render = toString;
      type = types.either sizeType (types.enum [ "none" ]);
      description = "Space limit for the dataset and its descendants.";
    };
    atime = {
      property = "atime";
      render = onOff;
      type = types.bool;
      description = "Whether to update access times on read (renders as on/off).";
    };
    autoSnapshot = {
      property = "com.sun:auto-snapshot";
      render = trueFalse;
      type = types.bool;
      description = ''
        Whether `zfs-auto-snapshot` snapshots this dataset (renders as the
        `com.sun:auto-snapshot` user property, spelled true/false).
      '';
    };
    autoSnapshotFrequent = {
      property = "com.sun:auto-snapshot:frequent";
      render = trueFalse;
      type = types.bool;
      description = ''
        Per-label override for the `frequent` (15-minute) auto-snapshot label;
        overrides {option}`autoSnapshot` for that label only.
      '';
    };
  };

  typedPropertyNames = attrNames typedProperties;
  freeformProps = p: removeAttrs p typedPropertyNames;
  typedProps = p:
    listToAttrs (concatMap
      (n:
        let t = typedProperties.${n}; in
        optional (p.${n} != null) (nameValuePair t.property (t.render p.${n})))
      typedPropertyNames);
  # Render the properties as ZFS expects them: non-null typed properties using
  # their rendered keys and values, and freeform keys verbatim.
  # Everything downstream (create args, disko-zfs spec, mount logic) consumes
  # only this rendered form.
  renderProperties = p: freeformProps p // typedProps p;
  # A property defined both ways (typed option *and* freeform ZFS name) has no
  # principled merge; asserted against below.
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

  # Flatten `pools.<name>.{properties,datasets}` into a single list of records
  # carrying each dataset's full name, rendered properties (typed properties
  # folded in under their ZFS names), encryption, and ownership:
  # `{ name; properties; conflicts; encryption; owner; group; mode; }`. The
  # pool root is included only when it has declared properties (see
  # `unmanagedRoots`).
  poolDatasets = pool: pcfg:
    let rootProps = renderProperties pcfg.properties; in
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
        properties = renderProperties d.properties;
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

  # Pools containing at least one encryption root are managed by a late oneshot;
  # every other pool goes through the stock early `disko-zfs` service.
  latePools = unique (map (d: poolOf d.name) encryptionRoots);
  isLate = d: elem (poolOf d.name) latePools;

  earlyDatasets = filter (d: !isLate d) datasetList;

  # Pool roots with children but no declared properties. They must be ignored, or
  # `disko-zfs`'s `expand_sub_datasets` would add an empty-property root entry and
  # then inherit-away (clobber) the pool root's real local properties.
  unmanagedRoots = attrNames
    (filterAttrs
      (_: pcfg: renderProperties pcfg.properties == { } && pcfg.datasets != { })
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
      # dataset, its parent (and, for encrypted children, the parent's now-loaded
      # key) already exists.
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

      # Per dataset: create it if missing, and for encryption roots, reconcile
      # `keylocation` and load the key. `keylocation` is pool state written at
      # creation; if the key file moves (say, an agenix secret is renamed),
      # unlock has to follow the configuration rather than fail against the
      # stale stored path, so it is re-set before every load-key. disko-zfs
      # never touches it (see `cryptoProperties`).
      #
      # Datasets are created `-u` (unmounted): first mounts then always go
      # through the mount step below, which `chattr -i`s the underlay before
      # mounting. Running a normal `zfs create` without `-u` would automatically
      # mount the dataset, preventing us from making the underlay immutable.
      #
      # The pool root (depth 1) is excluded: it always exists (the pool is
      # imported before this runs) and is reconciled by disko-zfs like any
      # other declared dataset.
      createDatasets = concatMapStringsSep "\n"
        (d:
          let
            name = escapeShellArg d.name;
            # Lazy: only forced in the encrypted branch, where `d.encryption`
            # is known non-null.
            keyLoc = escapeShellArg "file://${d.encryption.keyFile}";
          in
          if d.encryption != null then ''
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

      # Before each mount, make the underlay directory immutable (`chattr +i`):
      # while the dataset is unmounted, writes to the mountpoint path fail with
      # EPERM (even for root) instead of silently landing on the parent
      # filesystem and then blocking the next mount. Because this runs only if
      # the dataset is not mounted, the flag always lands on the underlay inode,
      # never the dataset root. Not every filesystem supports this flag, so this
      # is a best-effort attempt to guard against writes to the mountpoint while
      # the dataset is not mounted. If we can't chattr the underlay, we just log
      # a warning.
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
        ];
        text = ''
          # This file records datasets created by this run, so that step 4 can
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

          # 2. Reconcile properties with disko-zfs. Every dataset already exists
          #    after step 1, so disko-zfs only sets/inherits properties (drift
          #    from the declared spec). We feed it a snapshot of the pool via
          #    `--file` so it neither touches nor reports on other pools, and
          #    the encryption-intrinsic properties are in `ignoredProperties`.
          zfs get all -t filesystem --json --json-int -r ${escapeShellArg pool} \
            > "$RUNTIME_DIRECTORY/actual.json"
          disko-zfs --file "$RUNTIME_DIRECTORY/actual.json" --log-level info \
            apply --spec ${spec}

          # 3. Mount datasets that declare a path mountpoint.
          ${mountDatasets}

          # 4. Apply declared ownership to datasets created by this run.
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
      keyFile = mkOption {
        type = types.str;
        example = lib.literalExpression "config.age.secrets.moonpool-system-pass.path";
        description = ''
          Path to the file containing the encryption key (such as an agenix
          secret's `.path`). The dataset is created with `keylocation =
          file://<this path>` and unlocked from it at boot; if the path later
          changes, the stored `keylocation` is reconciled to follow it.

          To rotate the key itself, deploy the new file contents first, then
          run `zfs change-key <dataset>` on the host: it reads the *new* key
          from the stored `keylocation`, and the already-loaded key keeps the
          dataset available in the meantime.
        '';
      };

      keyFormat = mkOption {
        type = types.enum [ "passphrase" "hex" "raw" ];
        description = ''
          The `keyformat` for the encryption root.

          This must be specified, and has no default: it must match the actual
          contents of {option}`keyFile`.

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

          The configuration owns *every* declared local property of a dataset:
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
        # Three or four octal digits (a leading digit for setuid/setgid/sticky
        # is allowed --- setgid dirs are useful for shared trees).
        type = types.nullOr (types.strMatching "[0-7]{3,4}");
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
        type = propertiesSubmodule;
        default = { };
        example = { mountpoint = "none"; compression = "lz4"; };
        description = ''
          ZFS properties for the pool's *root* dataset (equivalent to disko's
          `rootFsOptions`); typed options plus freeform, as for dataset
          properties. If left empty while child datasets are declared, the
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
        })
      datasetList;

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
      datasets = listToAttrs (map datasetSpec earlyDatasets);
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
