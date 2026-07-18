# tranquility: storage

## Root Filesystem

`tranquility` boots unattended from a **mirrored pair of NVMe devices** with a
**ZFS-native-encrypted** root pool. The encryption key is released by the
machine's **TPM2** at boot via [clevis], with the ZFS passphrase as a manual
fallback (entered on the BMC console) if the TPM ever refuses.

- **Confidentiality:** the entire usable filesystem lives under the
  `tranquility-rpool/crypt` encryption root, so drives that leave the chassis
  (RMA, disposal, theft of disks) are unreadable.
- **High availability:** the two M.2s form a single ZFS mirror, and lanzaboote
  installs + signs the bootloader to *both* ESPs (using
  `extraEfiSysMountPoints`), so the system boots and runs from either disk
  alone.
- **Secure Boot:** the boot chain is signed and verified via [lanzaboote]. Keys
  are generated and enrolled on first boot.
- **Disposable rootfs:** nothing here needs backing up; the system is rebuilt
  from this Nix configuration.

> [!NOTE]
> By default the TPM seal uses an **empty policy** (no PCR binding). This
> protects data on disks removed from the machine and survives kernel/firmware
> updates, but does **not** defend against theft of the whole powered-on machine
> (it will unlock itself). That is an accepted trade-off for unattended boot.
> Enabling Secure Boot does not change this on its own --- to additionally
> resist boot-chain tampering, re-seal the key to PCR 7 (see
> [Optional: bind the disk key to Secure Boot](#optional-bind-the-disk-key-to-secure-boot-pcr-7)).

[clevis]: https://github.com/latchset/clevis
[lanzaboote]: https://github.com/nix-community/lanzaboote

## Initial install

uns from a NixOS installer on the target machine. The
TPM-sealing step (step 3) runs **after first boot, on the installed system** ---
there is no need to seal against the TPM from the installer, because the
configuration evaluates fine without the JWE (clevis is gated on
`builtins.pathExists` and the pool simply prompts for the passphrase until the
JWE exists).

### 1. Identify the NVMe devices

```console
ls -l /dev/disk/by-id/ | grep nvme
```

Edit `disko-config.nix` and replace the placeholder NVMe devices with the
`by-id` paths of the two devices.

### 2. Partition, format, and install

> [!IMPORTANT]
> Choose a strong passphrase for the `crypt` dataset and **record it in your
> password manager**. It is both the value sealed into the TPM (step 3) and the
> recovery key used to unlock the root filesystem on the BMC console if the TPM
> is ever unavailable.

```console
sudo nix \
  --extra-experimental-features 'nix-command flakes' \
  run 'github:nix-community/disko/latest#disko-install' -- \
  --flake '.#tranquility' \
  --disk nvme0 /dev/disk/by-id/nvme-${NVME0} \
  --disk nvme1 /dev/disk/by-id/nvme-${NVME1}
```

Enter the passphrase when disko prompts for the `crypt` dataset. No JWE exists
yet, so the first boot will prompt for this passphrase on the console**. This is
expected until step 3.

## Subsequent Setup

### 3. Seal the passphrase against the TPM

Run this **after the first boot, on the installed system** (not the installer).
This must be run as root, as the seal requires root access to the TPM
(`/dev/tpmrm0` is `root:tss`).

```console
sudo nix shell nixpkgs#clevis nixpkgs#tpm2-tools -c \
  sh -c "printf '%s' $RPOOL_PASSPHRASE | clevis encrypt tpm2 '{}'" \
  > hosts/tranquility/tranquility-rpool-crypt.jwe
```

The resulting `.jwe` is decryptable **only by this host's TPM**, so commit it to
the repo (same trust model as the TPM-backed SSH host key and agenix secrets),
then rebuild to activate unattended unlock:

```console
nixos-rebuild switch --flake '.#tranquility'
```

### 4. Verify unattended boot

Reboot and confirm the pool unlocks with no prompt:

```console
sudo journalctl -b -u 'clevis-*' --no-pager
zfs get keystatus,keylocation tranquility-rpool/crypt   # keystatus = available
```

### 5. Enroll Secure Boot keys

lanzaboote signs the boot chain with keys generated *on the host*
(`autoGenerateKeys`) and enrolls them via systemd-boot (`autoEnrollKeys`).
Enrollment only succeeds when the firmware is in **Setup Mode**.

1. In the UEFI firmware (via the BMC) put Secure Boot into **Setup Mode**, which
   deletes any existing Platform Keys.

   On the ASRockRack B650D4U BIOS, this setting is `Security > Secure Boot >
   Clear Secure Boot Keys`.
   
   > [!IMPORTANT]
   > Do this *before* the enrollment reboot. It's probably easiest to do this
   > before the install.
2. On the **first boot** after install, `generate-sb-keys` runs `sbctl
   create-keys` (into `/var/lib/sbctl`), then `prepare-sb-auto-enroll` writes the
   `PK`/`KEK`/`db` auth files to the primary ESP and re-signs all artifacts.
3. **Reboot.** With the firmware in Setup Mode, systemd-boot enrolls the keys
   and Secure Boot becomes active with *your* keys.
4. Verify:

```console
bootctl status | grep -i 'secure boot'   # Secure Boot: enabled (user)
sbctl status
sbctl verify                             # all ESP artifacts should be signed
```

> [!NOTE]
> The auto-enroll path stages the keys only on the primary ESP (`/boot`),
> and only takes effect if the firmware boots from that ESP while in Setup Mode.
> If you're still in Setup Mode after the reboot, enroll directly instead.
>  `sbctl enroll-keys`  writes the keys to the firmware regardless of which ESP
> booted, and only needs the ESP at the standard `/boot` (which is why it is mounted there):
>
> ```console
> sudo sbctl enroll-keys --microsoft # --microsoft keeps option-ROM keys trusted
> sudo bootctl status | grep -i 'secure boot'
> ```
>
> Then reboot, and if the firmware shows Secure Boot as `disabled (setup)` even
> after keys are present, toggle Secure Boot **on** in the BIOS.

> [!WARNING]
> This box has LSI SAS HBAs. Their option ROMs are typically Microsoft-signed,
> so `autoEnrollKeys.includeMicrosoftKeys = true` (the default we set) keeps
> them trusted. Because the system boots from NVMe rather than the HBAs, a
> blocked option ROM would not stop boot, but leaving the Microsoft keys
> enrolled avoids surprises. Do **not** set `allowBrickingMyMachine`.

### 6. Provision the TPM-sealed agenix identity

This host's SSH host key lives in the TPM (`services.ssh-tpm-hostkeys`) and
**cannot** be used by age to decrypt secrets, so agenix uses its own TPM-sealed
*age* identity (via `age-plugin-tpm`). This is independent of the clevis disk
key, and is enabled by `profiles.age.tpmHostIdentity.enable = true` in
`configuration.nix`.

> [!IMPORTANT]
> The host identity for `agenix` is permanently bound to the TPM. If the
> TPM/motherboard is replaced, regenerate the `age` identity, update
> `hostPubkey`, and `agenix rekey` again. Nothing is permanently lost because
> secrets are always recoverable from the 1Password master identity.

With `profiles.age.tpmHostIdentity` enabled, the `age-host-identity.service`
systemd unit generates `/etc/age/host-identity.txt` automatically on first boot
if the host does not already have one (it is sealed to this machine's TPM, with
no PIN, so decryption stays unattended). You only need to read back its
recipient.

If you want to generate it by hand instead (e.g. before the first rebuild has
brought the service in), the equivalent is:

```console
sudo install -d -m 0700 /etc/age
sudo age-plugin-tpm --generate -o /etc/age/host-identity.txt
sudo chmod 0600 /etc/age/host-identity.txt
```

Read back the recipient with `--tpm-recipient` and put it into
`configuration.nix` as `age.rekey.hostPubkey`, replacing the
`age1tpm1qREPLACE_ME` placeholder (the service also prints it to its journal):

```console
age-plugin-tpm -y /etc/age/host-identity.txt --tpm-recipient   # prints: age1tpm1…
```

> [!IMPORTANT]
> Using `--tpm-recipient` is necessary to ensure that `age-plugin-tpm` uses the
> `age1tpm1` prefix rather than `age1tag1` (the prefix for its newer `p256tag`
> recipient). If the recipient is `age1tag1`, then `agenix rekey` will get
> confused because it expects the prefix to include the actual name of the age
> plugin to use, which makes it sad when there is no `age-plugin-tag` on the
> path.

Then, from your admin machine, re-encrypt this host's secrets to the new
recipient and rebuild:

```console
agenix rekey            # or your usual agenix-rekey invocation (e.g. `nix run .#rekey`)
nixos-rebuild switch --flake '.#tranquility'
```

> [!NOTE]
> Until the `age` identity exists and `hostPubkey` is set, secret-dependent 
> services will fail to start, but the system still boots.

### Optional: verifying boot redundancy

Confirm the system boots from either disk alone (do this once, while you can
physically access the machine):

1. Power off, physically remove (or disconnect) `nvme0`, power on.
   - Firmware should fall back to `nvme1`'s `EFI/BOOT/BOOTX64.EFI` (the signed
     systemd-boot lanzaboote installed there), the TPM unlocks the pool, and the
     pool imports **degraded** but online.
2. Power off, reconnect `nvme0`, repeat with `nvme1` removed.
3. Reconnect both and resilver if needed:

```console
zpool status tranquility-rpool
zpool clear tranquility-rpool
zpool online tranquility-rpool <reconnected-partition>
```

### Optional: bind the disk key to Secure Boot (PCR 7)

The clevis JWE (step 2) uses an empty TPM policy so it survives updates but only
protects *removed* drives. Once Secure Boot is enrolled and verified, PCR 7 (the
Secure Boot policy) is stable across kernel updates, so you can re-seal the disk
key to it. The TPM then releases the key **only** under your signed boot
chain, defeating boot-chain tampering while staying unattended:

```console
printf '%s' 'YOUR-ZFS-PASSPHRASE' | clevis encrypt tpm2 '{"pcr_ids":"7"}' \
  > hosts/tranquility/tranquility-rpool-crypt.jwe
nixos-rebuild switch --flake '.#tranquility'
```

Only do this *after* `bootctl status` reports Secure Boot enabled, and keep the
passphrase fallback (it still works on the BMC console if PCR 7 ever changes).

## Operations

### Replacing a failed drive

```console
# Partition the replacement to match (4G ESP + rest ZFS), then:
zpool replace tranquility-rpool <old-part> /dev/disk/by-id/nvme-<NEW>-part2
# Re-run the bootloader install so the new ESP gets a signed copy of the
# bootloader (lanzaboote writes to every ESP in extraEfiSysMountPoints):
sudo nixos-rebuild boot --flake '.#tranquility'
```

### Rotating the TPM-sealed key

If you change the ZFS passphrase or move to a different TPM, regenerate the JWE
(step 2) with the new passphrase and `nixos-rebuild switch`. To change the
passphrase itself:

```console
zfs change-key tranquility-rpool/crypt   # prompts for old then new passphrase
```

## Storage pool setup

list SAS drives:

```console
$ lsblk -o NAME,VENDOR,MODEL,SERIAL,WWN -S
NAME VENDOR   MODEL            SERIAL               WWN
sda  SEAGATE  ST16000NM004J    ZR5DWPQ40000W3257HRN 0x5000c500da9d0c27
sdb  SEAGATE  ST16000NM004J    ZR5CGT060000C2127EAG 0x5000c500da3bc09f
sdc  SEAGATE  XS960LE70124     HSF030NS0000822150Z3 0x5000c500a18fae2b
sdd  SEAGATE  ST16000NM004J    ZR5CMG610000C3039SWZ 0x5000c500da3be65b
sde  NTAPCSSD X382_S1643960ATE S57SNA0R205377       0x5002538b012dda50
sdf  SEAGATE  ST960FM0003      Z87130ES0000822150Z3 0x5000c50030186723
sdg  WDC      WUH721816AL5204  2CHMU7PP             0x5000cca2a15c6554
sdh  WDC      WUH721816AL5204  2CHNGUYP             0x5000cca2a15d9a7c
sdi  WDC      WUH721816AL5204  2CHLHS6N             0x5000cca2a15a0534
sdj  NTAPCSSD X382_S1643960ATE S57SNA0R205376       0x5002538b012dda40
sdk  SEAGATE  ST960FM0003      Z87130AR0000822150Z3 0x5000c50030186713
```

Creating the zpool:

```console
sudo zpool create \
  -o ashift=12 \
  -o autoreplace=on \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  moonpool \
  raidz2 \
    /dev/disk/by-id/wwn-0x5000c500da9d0c27 \
    /dev/disk/by-id/wwn-0x5000c500da3bc09f \
    /dev/disk/by-id/wwn-0x5000c500da3be65b \
    /dev/disk/by-id/wwn-0x5000cca2a15c6554 \
    /dev/disk/by-id/wwn-0x5000cca2a15d9a7c \
    /dev/disk/by-id/wwn-0x5000cca2a15a0534 \
  special raidz2 \
    /dev/disk/by-id/wwn-0x5000c50030186723 \
    /dev/disk/by-id/wwn-0x5000c50030186713 \
    /dev/disk/by-id/wwn-0x5002538b012dda50 \
    /dev/disk/by-id/wwn-0x5002538b012dda40 \
  spare \
    /dev/disk/by-id/wwn-0x5000c500a18fae2b
```

ok it works 

```console
eliza@tranquility ~/flake $ zpool list && zpool status moonpool
NAME                SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
moonpool           90.8T  1.37M  90.8T        -         -     0%     0%  1.00x    ONLINE  -
tranquility-rpool   472G  13.7G   458G        -         -     0%     2%  1.00x    ONLINE  -
  pool: moonpool
 state: ONLINE
config:

        NAME                        STATE     READ WRITE CKSUM
        moonpool                    ONLINE       0     0     0
          raidz2-0                  ONLINE       0     0     0
            wwn-0x5000c500da9d0c27  ONLINE       0     0     0
            wwn-0x5000c500da3bc09f  ONLINE       0     0     0
            wwn-0x5000c500da3be65b  ONLINE       0     0     0
            wwn-0x5000cca2a15c6554  ONLINE       0     0     0
            wwn-0x5000cca2a15d9a7c  ONLINE       0     0     0
            wwn-0x5000cca2a15a0534  ONLINE       0     0     0
        special
          raidz2-1                  ONLINE       0     0     0
            wwn-0x5000c50030186723  ONLINE       0     0     0
            wwn-0x5000c50030186713  ONLINE       0     0     0
            wwn-0x5002538b012dda50  ONLINE       0     0     0
            wwn-0x5002538b012dda40  ONLINE       0     0     0
        spares
          wwn-0x5000c500a18fae2b    AVAIL

errors: No known data errors
```

### Dataset layout and encryption

The pool is created and grown **statefully** (drives fail and get replaced), but
its **dataset layout is declarative**, defined once in `configuration.nix` under
`profiles.zfs.pools` (a thin wrapper over [`disko-zfs`], see
`modules/nixos/profiles/zfs/datasets.nix`). The layout is:

```
moonpool
└─ ds1
   ├─ media                       unencrypted, no auto-snapshot   → /srv/media
   ├─ system                      ENCRYPTED root, auto-snapshot   (service state)
   └─ users
      └─ eliza                    ENCRYPTED root, auto-snapshot
         ├─ shares                → /srv/users/eliza/shares
         └─ backups               → /srv/users/eliza/backups
```

- **`media`** is unencrypted (re-downloadable, non-sensitive) and not
  snapshotted. `recordsize=1M`: large sequential files, fewer indirect blocks
  (which also relieves the special vdev).
- **`system`** holds state for data-serving services. Per-service child datasets
  (added later, mounted into `/var/lib/<service>`) inherit its key.
- Each **user** is their own encryption root with its own key, so their data is
  cryptographically isolated. Add a user by adding another encrypted child under
  `users`. `shares` and `backups` inherit the user's key.
- **`shares`** holds a mixed corpus: the largest category is multi-megabyte
  PDFs (~1.2--35MB), plus a tail of smaller files. `recordsize=1M` suits the
  big files (whole-file sequential I/O, 8x fewer indirect blocks, so less
  metadata on the special vdev); files smaller than the recordsize are stored
  as a *single block of roughly the file's size* (recordsize is a cap, not an
  allocation unit), so the cap costs the small files nothing.
  `special_small_blocks=512K` routes those small blocks (files up to ~512K)
  to the special vdev's SSDs --- the population where per-file HDD seek
  latency hurts most --- while the 1M PDF chunks stay on the HDDs. **Never**
  set the threshold at or above the recordsize: that routes *all* data to the
  special vdev.

  Metadata capacity is protected from this data by a built-in gate
  (`zfs_special_class_metadata_reserve_pct`, module parameter, default 25):
  metadata always bypasses it, while small-block *data* is refused once the
  class passes `100 - pct` percent allocated --- a guaranteed metadata-only
  floor of ~875GiB raw at the default. The small-file tail's aggregate is
  bounded by its own smallness, so the default reserve is ample; if the
  small-block population grows beyond expectations, raise the parameter (it
  is runtime-tunable via `/sys/module/zfs/parameters/`). Watch the special
  vdev's fill with `zpool list -v moonpool`.
- **`backups`** sets `recordsize=1M` for the same reason. Never set
  `special_small_blocks` here: chunk-based backup tools (borg/restic) write
  exactly midsize blocks and would soak terabytes into the special vdev.
- Add a `quota` property to a user's encryption root to cap their usage. It
  must be *declared* in the configuration --- see property ownership below.
- 15-minute (`frequent`) auto-snapshots are disabled pool-wide via
  `com.sun:auto-snapshot:frequent=false`; hourly and coarser labels still run
  on the snapshotted subtrees. (SSD wear from snapshot churn is negligible ---
  this is hygiene, not endurance management: 15-minute recovery points buy
  nothing for this workload.)

#### How it is applied

`moonpool` contains encrypted datasets, so the whole pool is managed by a late
systemd oneshot (`zfs-datasets-moonpool.service`) rather than the early
`disko-zfs` service. The oneshot runs after the pool is imported
(`boot.zfs.extraPools`) *and* after agenix has decrypted the encryption
passphrases, then it creates any missing datasets (parent-first), loads keys,
reconciles properties with `disko-zfs`, and mounts everything. Services that
need the pool declare the paths they use:

```nix
systemd.services.jellyfin.requiresZfsMounts = [ "/srv/media" ];
```

Each path is resolved (at eval time --- unknown paths are an error) to the
dataset whose mountpoint is its longest prefix, and the service gains
**`requires` and `after`** on `zfs-datasets-moonpool.target`. `requires`
matters: `after` alone only orders, and a service without `requires` will
still start when unlock fails and write into the empty mountpoint directory
on the root filesystem. Failure to unlock the pool never blocks the rest of
the system from booting.

Two operational invariants:

- **Layout changes are applied by `nixos-rebuild switch`, as a reload.** The
  oneshot's runner is idempotent, so switch *reloads* the unit (re-runs the
  runner) rather than restarting it --- a restart's stop would propagate
  through the target's `Requires` and strand every consumer stopped. If the
  reload fails (e.g. a new dataset's key is missing), the switch reports it,
  but the target stays active and consumers of the previously-working layout
  keep running; fix and re-switch. One race to know about: a *new* service
  added in the same switch as the dataset it consumes may start before the
  reload finishes creating that dataset, fail (loudly, against the immutable
  or absent mountpoint), and need one `systemctl start` after --- or a
  `Restart=on-failure` in the service itself.

- **The configuration owns every local property of a declared dataset.** A
  hand-run `zfs set` (quota, sharenfs, sharesmb, ...) on a declared dataset is
  drift, and is reverted (`zfs inherit`) the next time the oneshot runs.
  Declare properties in `configuration.nix`, or add them to
  `disko.zfs.settings.ignoredProperties`.

- **Mountpoint underlay directories are made immutable** (`chattr +i`) by the
  oneshot before each mount, so that when a dataset is *not* mounted, writes
  to its mountpoint path fail with `EPERM` (even as root) instead of silently
  landing on the root pool and then blocking the mount. Two consequences:
  the flag is invisible while the dataset is mounted (it lives on the
  underlay inode), and an *abandoned* mountpoint directory cannot be removed
  --- even by root --- until you clear the flag: `chattr -i <dir> && rmdir
  <dir>`.

[`disko-zfs`]: https://github.com/numtide/disko-zfs

### Provision the dataset encryption keys

The `system` and per-user datasets are encrypted with `keyformat=passphrase`.
The passphrases are agenix-rekey secrets with a `passphrase` generator (six
random words), decrypted unattended at boot via this host's TPM-sealed identity.

1. Generate and rekey the passphrases (on the admin machine), then commit them:

   ```console
   agenix generate   # creates secrets/generated/moonpool-*-pass.age
   agenix rekey -a
   ```

2. **Recommended:** copy each passphrase into 1Password so the datasets can be
   unlocked on *any* machine with nothing but the password manager (the whole
   point of `keyformat=passphrase`). Read the generated values with:

   ```console
   agenix view   # interactive; decrypts with the master identity
   ```

   Without this, offline/foreign-machine recovery also needs this flake plus the
   agenix master identity.

3. Rebuild. On the next boot the oneshot creates, unlocks, and mounts the
   datasets:

   ```console
   nixos-rebuild switch --flake '.#tranquility'
   systemctl status zfs-datasets-moonpool.service
   zfs get -r keystatus,mounted moonpool
   ```

4. **Test the recovery path once.** The disaster-recovery story rests on the
   invariant *key-file contents ≡ what you type at the prompt* (libzfs strips
   the file's trailing newline for `keyformat=passphrase`, so it should hold
   --- verify it does). For each encryption root, with the 1Password copy of
   the passphrase:

   ```console
   sudo zfs unload-key moonpool/ds1/system
   sudo zfs load-key -L prompt moonpool/ds1/system   # type the 1Password passphrase
   ```

   `-L prompt` overrides the key *source* for this load only; the stored
   `keylocation` is untouched, so no cleanup is needed afterwards. Note that
   `unload-key` refuses while datasets using the key are mounted --- unmount
   the subtree first, or do this before the datasets hold any data.

#### Rotating a dataset passphrase

`zfs change-key` re-wraps the dataset's master key; data is not re-encrypted,
and child datasets are unaffected. Order matters --- `change-key` reads the
*new* key from the stored `keylocation` (the agenix file), so deploy the new
secret first:

```console
# On the admin machine: regenerate this secret, rekey, commit.
agenix generate -f moonpool-user-eliza-pass
agenix rekey -a

# Deploy so /run/agenix/... contains the new passphrase (the key is still
# loaded from boot, so nothing breaks in between):
nixos-rebuild switch --flake '.#tranquility'

# On tranquility: re-wrap with the new passphrase from the key file.
sudo zfs change-key moonpool/ds1/users/eliza
```

Then update the copy in 1Password. The old passphrase no longer unlocks the
dataset (but old raw `zfs send` streams remain wrapped with the old key).

#### Manual unlock

If the TPM is ever unavailable, or when importing the pool on another machine,
unlock a dataset by hand with its 1Password passphrase:

```console
zfs load-key -L prompt moonpool/ds1/users/eliza
```
