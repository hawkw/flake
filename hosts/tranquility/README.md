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
