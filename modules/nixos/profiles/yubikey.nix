# YubiKey config
#
# == Overview ==
#
# This module configures a comprehensive, opinionated multi-factor
# authentication setup using YubiKeys for a small fleet of machines (okay, I
# mean my homelab, but this is a bit of an enterprise LARP). At a high level, we
# have the following goals:
#
# 1. Support both _local authentication_ (i.e. by plugging a YubiKey into my
#    laptop) and _remote authentication_ (i.e. authenticating a SSH session to
#    a remote server *using* the YubiKey plugged into my laptop).
#
# 2. Disaster recovery in the event of the loss or destruction of a YubiKey.
#    The scheme must support multiple backup hardware security tokens; losing
#    one YubiKey MUST not lock me out of all my computers forever.
#
# 3. Disaster recovery in the event of the loss of my laptop. Anything stored on
#    my laptop's single non-redundant NVMe SSD MUST be able to be
#    reconstructed if the disk fails or if I drop my computer into the Bay.
#
# 4. Pervasive multi-factor auth: all authentication must require both
#    "something you have" *and* "something you know". By allowing multiple
#    hardware security tokens to support (2), we are therefore also creating
#    additional risks for a token to be compromised. Therefore, theft of a
#    YubiKey alone MUST not give an attacker the ability to access my systems.
#
# 5. Physical presence is always required. I should have to confirm all auth
#    requests, so that a machine compromised by a remote attacker
#    cannot escalate privileges just because the YubiKey is plugged in.
#
# 6. Convenience. I don't *really* want to have to type a PIN or passphrase
#    *every* time I sign a Git commit or run a SSH command. If my laptop is
#    already unlocked, that should be sufficient to confirm my identity; I
#    should only have to touch the YubiKey to confirm an auth request, rather
#    than typing a PIN *and* touching the key.
#
# == Design ==
#
# For remote authentication (and Git commit signing), we use `ed25519-sk` SSH
# keys for each YubiKey. We use *non-resident* keys, so that actually signing a
# request requires both the YubiKey *and* an `id_ed25519_sk` key handle file,
# and the keys cannot be recovered completely with only possession of a YubiKey.
# This allows us to not require a PIN for the SSH keys without allowing an
# attacker who has access to a YubiKey to recover my SSH keys. Instead, the
# laptop itself, which contains the key handle files, serves as a second
# authentication factor; and because of full disk encryption, this is both a
# "something you know" factor *and* a "something you have" factor.
#
# However, if the SSH keys are only usable if you have both a YubiKey *and* a
# file that only exists on my laptop, that creates a problem for requirement
# (3), disaster recovery. When the M.2 in my Framework dies, that renders the
# keys unusable. To resolve this, we additionally escrow the key handle files in
# 1Password. This escrow is relatively safe because the key handle files are not
# sufficient to use the keys; one must both compromise my 1Password account
# *and* physically acquire a YubiKey to authenticate with my SSH credentials.
# This feels like a pretty reasonable level of security while still allowing a
# disaster recovery path where I can continue using the same SSH keys even if my
# laptop is run over by a cement mixer.
#
# For local authentication, we use the PAM U2F module from Yubico to log into
# the computer. This requires a PIN in addition to physical access to the
# YubiKey, so it is also multi-factor. You can't just plug the YubiKey into my
# laptop and be authenticated, but a YubiKey is required in addition to the PIN.
# This part is pretty standard. The part that's a bit weird is that, because I
# would like to use YubiKeys for local interactive auth on multiple machines in
# my "fleet", and because I would like to allow any of the YubiKeys to be used
# for local auth, the authfile is stored as an `agenix` secret, so that multiple
# machines can be configured to use PAM U2F auth in their NixOS configs.
#
# Finally, we also use YubiKey-backed age identities for `agenix`. These master
# identities are represented by handle files that are stored in this repo, but
# these are, again, just handles to the hardware-backed keys.
#
# == Implementation details ==
#
# In addition to providing the NixOS configs to actually use YubiKey auth (i.e.
# the PAM U2F stuff), this module also generates a provisioning script
# (creatively named `ykprovision`) which is used to enroll a YubiKey in the auth
# scheme. This script generates SSH keys and escrows the sk handle files in
# 1Password, generates the age recipient handles for `agenix`, and generates the
# PAM U2F credentials, and encrypts them as agenix secrets.
#
# Running the script is sufficient to provision a YubiKey for use with this
# scheme. Once it's been run, I can stick that YubiKey in a tamper-evident bag,
# put the bag in a safe, mail the safe to my mom, and never touch it again until
# I lose my primary key, and it should still be able to authenticate to my
# systems identically to the primary key. The provisioning script does
# everything that requires the key to be physically present.
#
# YubiKeys are identified by their serial numbers, which can be read from the
# device. Using the serial numbers in the name of the various handle files and
# key escrow bits generated from each YubiKey allows the provisioning script to
# be more or less idempotent, and resumable if it fails partway through. This is
# probably unnecessary, but it feels cool. Did I mention "enterprise LARP"?
#
# Revocation is somewhat automated by a similar script. `ykrevoke <serial>`
# removes a key's in-repo artifacts (including the stale *generated* PAM
# authfile) and prints a checklist of the steps it can't do from here (GitHub
# key removal, 1Password cleanup, rebuilds and reboots).
#
# The module also installs a udev rule that symlinks /dev/yubikey/<serial> for
# each attached YubiKey, as a zero-I/O way for scripts (e.g. the git signing-key
# selector in the home-manager config) to discover which keys are physically
# present. This depends on the serial being visible in the USB descriptor, which
# ykprovision's OTP phase configures. This part was kind of disgusting due to
# the Yubikey firmware being weird and annoying about when it is willing to
# expose its serial as a USB device.
#
# In the Nix config for PAM U2F, we stitch together multiple credentials into
# one authfile using an `agenix` `generator`. This allows the provisioning
# script to just produce an individual credential secret for each YubiKey,
# rather than having it mutate one credential file. Adding a new YubiKey to PAM
# U2F does not require mutating an existing authfile, and stitching them
# together is instead figured out by Nix when the config is evaluated.
#
# Similarly, other modules in this repo stitch together things like SSH
# `authorized_keys` configs for the servers from the pubkeys in this repo.
{ config, lib, pkgs, inputs, self, ... }:

with lib;
let
  cfg = config.profiles.yubikey;

  # --- constants shared by ykprovision and the various configs ---

  # These are deliberately not NixOS options, because they must be identical
  # across the whole fleet, rather than overridden. In particular, the PAM
  # origin is baked into the generated credentials at provisioning time and must
  # not change.

  # The base domain, used to namespace URL-shaped identifiers: the PAM
  # relying-party ID and the SSH key comments.
  baseDomain = "elizas.website";

  # Relying-party ID baked into PAM U2F credentials at enrollment.
  #
  # DON'T CHANGE THIS: changing it invalidates every credential already
  # generated. The `pam://` prefix keeps this from being a valid WebAuthn
  # domain, preventing it from accidentally being used for WebAuthn.
  pamOrigin = "pam://${baseDomain}";

  # The user the PAM U2F authfile authorizes, and for use in SSH key comment
  # strings.
  user = "eliza";

  # Per-YubiKey PAM U2F credentials: one agenix `intermediary` secret per
  # YubiKey (a bare pamu2fcfg credential, no username prefix). Secrets are
  # created by a provisioning script and deleted by the revocation script. The
  # authfile is generated from these below.
  pam_u2fCredentialsDir = "secrets/pam-u2f";
  pam_u2fAuthfileSecret = "pam-u2f-authfile";

  # The shared registry of enrolled-YubiKey names and locations
  yubikeysLib = import ../../../lib/yubikeys.nix { inherit lib; };

  # Repo-relative artifact locations (both scripts run from the flake
  # root).
  #
  # These are public material only. The sk private key handles never enter the
  # repo. Putting pubkeys in the `secrets` dir is therefore a bit goofy, but I
  # couldn't think of a better location.
  authorizedKeysDir = repoRelative yubikeysLib.ssh.pubkeyDir;
  masterIdentitiesDir = "secrets/master-identities";

  # Filename prefix for the SSH keyfiles (`id_ed25519_yk<serial>`).
  sshKeyfilePrefix = yubikeysLib.ssh.keyfilePrefix;

  # Recover the working-tree-relative form of a path option that points into
  # the flake source. Option values are store paths (the flake's store
  # copy). Because the script operates from a Git checkout of the repo,
  # rather than the version in the Nix store, we need to get the
  # repo-relative suffix of these path in order to figure out where to put
  # stuff.
  repoRelative = p:
    let
      src = toString self + "/";
      str = toString p;
    in
    if hasPrefix src str then removePrefix src str
    else throw "profiles.yubikey: path ${str} is not inside the flake source; cannot relativize it for ykprovision";

  # Where `agenix generate` writes generated secrets, derived from the
  # agenix-rekey config (if that's set, see profiles/age.nix). The script
  # needs to know where agenix will put these so that it can invalidate
  # stale authfiles when provisioning. The fallback matches age.nix's
  # setting for hosts that enable this profile without the age profile.
  generatedSecretsDir =
    if config.age.rekey.generatedSecretsDir != null
    then repoRelative config.age.rekey.generatedSecretsDir
    else "secrets/generated";

  # A little fragment of bash for checking whether or not we are actually in the
  # flake repo dir. Both the provisioning and revoking scripts use this.
  checkFlakeRoot = ''
    echo "preflight: running from the flake root?" >&2
    if [ ! -f flake.nix ] || [ ! -d ${escapeShellArg masterIdentitiesDir} ]; then
      echo "error: run me from the flake root (expected flake.nix and ${masterIdentitiesDir}/)" >&2
      exit 1
    fi
    echo "--> okay, looks like it" >&2
  '';

  # Another shared shell helper for interactive yes/no confirmation.
  confirmOrAbort = ''
    confirm_or_abort() {
      select STRICTREPLY in "Yes" "No"; do
        RELAXEDREPLY=''${STRICTREPLY:-$REPLY}
        case "$RELAXEDREPLY" in
          Yes | yes | y )
              echo "--> ...if you say so!" >&2
              return 0;;
          No  | no  | n ) exit 1;;
        esac
      done
      # `select` only exits its loop on EOF.
      echo "error: EOF on confirmation prompt; aborting" >&2
      exit 1
    }
  '';

  # YubiCo's USB vendor ID.
  yubicoVid = yubikeysLib.usb.vendorId;

  # ykprovision: one-stop provisioning for a new YubiKey.
  #
  # Provisions everything that requires the key to be physically present:
  #
  #   - neutralizes the Yubico OTP applet (unused, and accidental touches
  #     type junk into whatever has focus) and makes the serial number
  #     visible in the USB descriptor, which the udev rule below needs (see
  #     the OTP phase in the script for the gory details),
  #   - a non-resident ed25519-sk SSH key (touch per signature, no PIN at
  #     us
  #   - a PIV-backed age identity (PIN once per session, touch cached for 15
  #     seconds per decryption),
  #   - the PIV access credentials guarding that identity: PIN (memorized,
  #     prompted), PUK (generated, escrowed in 1Password, since the factory PUK
  #     would let an attacker with physical access reset the PIN and use the
  #     identity), and management key (random, stored on-device PIN-protected).
  #     Sadly, we must use the legacy TDES management key until
  #     age-plugin-yubikey#92 lands upstream. I'm choosing not to worry too much
  #     about that.
  #   - the FIDO2 PIN (required by pam_u2f `pinverification`),
  #   - a PAM U2F credential (non-resident, PIN + touch at auth).
  #
  # Once a YubiKey has been provisioned, everything that's authenticated against
  # it (i.e. SSH authorized_keys, agenix masterIdentities, the pam_u2f config
  # below) is generated from the Nix config in this repo using the public key
  # files output by the provisioning script. This way, consumers can be set up
  # to authenticate with that YubiKey without requiring its physical presence
  # when the Nix config is evaluated.
  #
  # Identity and idempotency:
  #
  #   - Everything is uniquely ID'd by the device serial: local files, repo
  #     artifacts, and 1Password item titles.
  #   - An optional user-provided $YUBIKEY_LABEL can be provided; it is used
  #     only as metadata.
  #   - Each phase is check-then-do. A failed run (of which I have already
  #     experienced many) can be safely resumed by re-running the script. This
  #     is safe because every step reuses durable state that exists in either
  #     the repo, on the yubikey, or in 1Password.
  #
  # 1Password escrow (two items per key):
  #
  #   - `YubiKey <serial> passphrase` holds the keyfile passphrase
  #     (xkcdpass, 6 words off the EFF long list, ~77 bits). It is escrowed
  #     *before* keygen runs and read back when actually creating the keyfile.
  #     Once ssh-keygen has succeeded, this item is the only durable copy of
  #     the passphrase.
  #   - `YubiKey <serial>` (a "Secure Note") holds the encrypted keyfile and
  #     attestation as file attachments, pubkeys, and device metadata. We don't
  #     use the "SSH Key" 1Password category for this, because that expects
  #     1Password to actually own the key, and it doesn't know about ed25519-sk
  #     keys.
  #
  # These are split across two items to protect against accidental disclosure of
  # both the sk handle file and passphrase at the same time. Compromising the
  # 1Password *account* still compromises both, but separate items at least
  # makes it slightly harder to expose them both by mistake.
  #
  # Known accepted exposure: the SSH key passphrase (and likewise the PIV PUK)
  # transits the script's shell memory and the argv of `op item create`/`op item
  # edit`, `ssh-keygen`, and `ykman piv access change-puk`. This doesn't really
  # matter that much, because the provisioning will be run on a single user
  # machine that is trusted at the time of provisioning.
  ykprovision =
    let
      # The 1Password vault escrow items live in.
      escrowVault = "Escrow";

      # Domain suffix for SSH key comments, which are generated as
      # `<user>@yk<serial>.sk.<baseDomain`.
      sshCommentDomain = "sk.${baseDomain}";
    in
    with pkgs; writeShellApplication {
      name = "ykprovision";
      runtimeInputs = [
        # EXTREMELY SERIOUS WARNING: you may feel tempted to put the
        # `_1password-cli` package here, so that it can be on the PATH for the
        # script. hilariously, this actually makes 1Password *not work*, as the
        # version of the CLI that you get when referencing the nix store path
        # directly is somehow unable to talk to the desktop app running on the
        # same host. instead, one must set `programs.1password.enable`. i don't
        # know why this is, but putting it here breaks it. cool.
        yubikey-manager
        openssh
        age-plugin-yubikey
        pam_u2f
        # Generates the word-based keyfile passphrases.
        xkcdpass
        # The agenix-rekey CLI, used to encrypt PAM U2F credentials to the
        # master identities.
        inputs.agenix-rekey.packages.${pkgs.stdenv.hostPlatform.system}.default
        coreutils
        git
        gnugrep
        gnused
        jq
      ];
      text = ''
        # Shared constants; see the module header.
        ORIGIN=${escapeShellArg pamOrigin}
        VAULT=${escapeShellArg escrowVault}
        # The username to generate PAM-U2F creds and SSH keys for.
        # N.B. that this variable can't be called USER, since that's the var set
        # by login shells, and we don't want to clobber it for child processes.
        KEY_USER=${escapeShellArg user}
        AUTHORIZED_KEYS_DIR=${escapeShellArg authorizedKeysDir}
        MASTER_IDENTITIES_DIR=${escapeShellArg masterIdentitiesDir}
        PAM_CREDENTIALS_DIR=${escapeShellArg pam_u2fCredentialsDir}
        PAM_AUTHFILE_SECRET=${escapeShellArg pam_u2fAuthfileSecret}
        GENERATED_SECRETS_DIR=${escapeShellArg generatedSecretsDir}
        SSH_KEYFILE_PREFIX=${escapeShellArg sshKeyfilePrefix}
        SSH_COMMENT_DOMAIN=${escapeShellArg sshCommentDomain}

        ${checkFlakeRoot}

        echo "preflight: looking for yubikeys..." >&2
        # N.B.: this check won't work with YubiKey Security Key products, which
        # don't have serial numbers. Luckily, I don't have any of those. :)
        mapfile -t SERIALS < <(ykman list --serials)
        case "''${#SERIALS[@]}" in
          0)
            echo "error: I see no YubiKey here (are you sure it's plugged in?)" >&2
            exit 1
            ;;
          1)
            SERIAL="''${SERIALS[0]}"
            ;;
          *)
            echo "error: I see more than one YubiKey here (serials: ''${SERIALS[*]})" >&2
            echo "please attach only the key being provisioned, and re-run" >&2
            exit 1
            ;;
        esac
        echo "--> okay, found $SERIAL" >&2

        ${yubikeysLib.usb.serialFunctions}

        # Checks if a Yubikey's serial is visible as a USB device. This is used
        # in the OTP applet configuration step below.
        serial_visible() {
          local serials
          serials="$(sysfs_yk_serials)"
          grep -qx "$SERIAL" <<< "$serials"
        }

        # `ykman list` tolerates the device being mid-enumeration (it just won't
        # list it), so it can be used to poll for presence after a config change
        # reboots the key.
        wait_for_yubikey() {
          for _ in $(seq 1 30); do
            if ykman list --serials 2>/dev/null | grep -qx "$SERIAL"; then
              return 0
            fi
            sleep 1
          done
          echo "error: YubiKey $SERIAL hasn't come back after 30 seconds" >&2
          echo "try unplugging it and plugging it back in, then re-run to resume" >&2
          exit 1
        }

        # --- OTP applet: neutralize typing, expose the serial ---
        #
        # This is probably the most complex and weird part of this script. It
        # has two goals, which are unfortunately entangled quirks of the YubiKey
        # firmware:
        #
        #  1. Accidental touches must not type junk: when Yubico OTP keys exist,
        #     touching the YubiKey while another applet is not asking for auth
        #     triggers slot 1 (short) / slot 2 (long) keystroke emission as a
        #     USB-HID keyboard device. If the Yubikey junk typing (which is
        #     identifyable by its `cc` prefix) makes it into a chat app, your
        #     friends and/or coworkers will make fun of you, so we should try
        #     to stop it from doing that. Luckily, we're not using OTP for
        #     anything.
        #  2. The serial must appear in the USB descriptor (iSerialNumber)
        #     so this module's udev rule can produce /dev/yubikey/ symlinks.
        #     The SERIAL_USB_VISIBLE flag lives *in a slot configuration*
        #     and only takes effect while the OTP application is
        #     USB-enabled. Unfortunately, this means we cannot do the
        #     traditional thing of `ykman config usb --disable OTP` to stop it
        #     from typing garbage when Yubico OTP is not in use, since that also
        #     makes the device stop advertising its serial. Instead, we must
        #     configure slot 1 to be silent-but-usable.
        #
        # Luckily, an *empty* OTP credential slot emits nothing, and a
        # *challenge-response* slot emits nothing on touch (it only answers
        # host-initiated challenges). So slot 2 is emptied and slot 1 gets an
        # inert random chalresp config. Slot 1 must be configured-but-silent:
        # the flag needs somewhere to live (`ykman otp settings` refuses empty
        # slots).
        #
        # Order matters: `otp chalresp` writes a fresh slot config,
        # CLOBBERING the visibility flag; `otp settings` preserves the
        # stored secret while rewriting the flags. Always chalresp first,
        # then settings.
        #
        # Unlike `ykman config usb --disable OTP`, this approach does have the
        # downside of *nuking* the factory Yubico OTP credential in slot 1 (the
        # AES key registered with YubiCloud at manufacture). This is
        # irreversible, which is *probably* fine since I don't intend to use
        # legacy OTP auth. Nonetheless, it's nice to know that OTP is not
        # permanently lost. If YubiCloud is ever needed again, program a fresh
        # credential and upload it:
        #
        #     ykman otp yubiotp 1 --serial-public-id -g -G -O creds.csv
        #     # submit creds.csv at https://upload.yubico.com
        #
        # (the new credential gets a `vv...` public ID; the factory `cc...`
        # identity is gone forever). The throwaway chalresp secret needs no
        # escrow: it is registered nowhere and authenticates nothing.
        #
        # The descriptor only updates on re-enumeration, so first-time
        # configuration ends with an unplug/replug prompt.

        # Are the OTP slots in their neutralized state (slot 2 empty, slot 1
        # inert on touch)? `otp info` reports slot 2's emptiness directly,
        # but it can't distinguish a chalresp config in slot 1 from the
        # factory junk-typing credential: both are just "programmed". So
        # we test-fire it: only a challenge-response config answers `otp
        # calculate`, and ours is minted without touch-required, so a
        # successful touchless calculate proves slot 1 emits nothing on
        # touch. Any failure (including the OTP application being disabled
        # over USB, as under the old scheme) means "can't prove neutralized"
        # and we run the sequence, which is safe from any starting state.
        otp_neutralized() {
          local info
          info="$(ykman --device "$SERIAL" otp info 2>/dev/null)" || return 1
          grep -q "Slot 2:[[:space:]]*empty" <<< "$info" || return 1
          ykman --device "$SERIAL" otp calculate 1 00 > /dev/null 2>&1 || return 1
        }

        echo "config: is the OTP applet configured (serial visible, slots inert)?" >&2
        if serial_visible && otp_neutralized; then
          echo "--> yes, the OTP applet is already configured. nothing to do here." >&2
        else
          echo "--> no; configuring the OTP applet..." >&2
          if ! ykman --device "$SERIAL" config usb --list | grep -qi "otp"; then
            echo "config: enabling the OTP interface (the YubiKey will reboot)..." >&2
            ykman --device "$SERIAL" config usb --force --enable OTP
            wait_for_yubikey
          fi
          if ykman --device "$SERIAL" otp info | grep -q "Slot 2:[[:space:]]*programmed"; then
            echo "config: emptying OTP slot 2..." >&2
            ykman --device "$SERIAL" otp delete --force 2
          fi
          # stdout is discarded because --generate prints the (unused) secret.
          # This isn't security critical, since...we don' tuse it for anything,
          # but there's no reason to print it.
          echo "config: replacing OTP slot 1 with an inert chalresp credential..." >&2
          ykman --device "$SERIAL" otp chalresp --force --generate 1 > /dev/null
          echo "config: setting SERIAL_USB_VISIBLE on slot 1..." >&2
          ykman --device "$SERIAL" otp settings --force --serial-usb-visible 1
          # The replug is only needed to get the new flag into the
          # descriptor; a key that already advertises its serial (i.e. one
          # that only needed its slots nuked) skips it.
          if serial_visible; then
            echo "--> okay; serial was already visible, that's good!" >&2
          else
            echo "the new flag only takes effect when the device re-enumerates:" >&2
            read -rp "please unplug YubiKey $SERIAL, plug it back in, then press enter... " _ack
            wait_for_yubikey
            if ! serial_visible; then
              echo "error: the serial still isn't in the USB descriptor after replugging." >&2
              echo "re-run to retry; if it persists, debug with 'lsusb -v -d 1050:'." >&2
              exit 1
            fi
            echo "--> okay, serial $SERIAL is now visible" >&2
          fi
        fi

        KEYFILE="$HOME/.ssh/''${SSH_KEYFILE_PREFIX}''${SERIAL}"
        ATTESTATION="$KEYFILE.attestation"
        REPO_PUBKEY="$AUTHORIZED_KEYS_DIR/''${SSH_KEYFILE_PREFIX}''${SERIAL}.pub"
        AGE_STUB="$MASTER_IDENTITIES_DIR/yubikey-''${SERIAL}.txt"
        AGE_RECIPIENT_FILE="$MASTER_IDENTITIES_DIR/yubikey-''${SERIAL}.pub"
        PAM_CRED_FILE="$PAM_CREDENTIALS_DIR/yubikey-''${SERIAL}.age"
        KEY_ITEM="YubiKey ''${SERIAL}"
        PASS_ITEM="YubiKey ''${SERIAL} passphrase"

        # Untracked files are invisible to flake evaluation (and thus to the
        # authfile generator's readDir). Adding them using intent-to-add keeps
        # every emitted repo artifact visible without staging content.
        #
        # It's important to ensure these are tracked, because silent omission of
        # a credential would assemble an authfile that quietly lacks a key.
        emit_file() {
          git add --intent-to-add "$1"
          echo "--> wrote $1" >&2
        }

        ${confirmOrAbort}

        echo "preflight: are you running as the user keys will be minted for?" >&2
        WHOAMI=$(whoami)
        if [ "$WHOAMI" != "$KEY_USER" ]; then
          echo "--> no, expected to be provisioning keys for '$KEY_USER', but you are logged in as '$WHOAMI'" >&2
          echo "--> do you want to continue?" >&2
          confirm_or_abort
        else
          echo "--> yes, you are provisioning keys for '$KEY_USER'" >&2
        fi

        echo "preflight: will the key be labeled?" >&2
        if [[ -z "''${YUBIKEY_LABEL:-}" ]]; then
          echo "--> no value for YUBIKEY_LABEL provided! key will not be labeled" >&2
          echo "--> do you want to continue?" >&2
          confirm_or_abort
        else
          echo "--> yes, label is '$YUBIKEY_LABEL'" >&2
        fi

        echo "preflight: is 1Password CLI signed in?" >&2
        if op whoami > /dev/null 2>&1; then
          echo "--> okay, seems to be" >&2
        else
          echo "--> no; running 'op signin'..." >&2
          # With desktop-app integration, `op signin` pops the app's auth prompt
          # and prints nothing. If the desktop app is not present, signing in
          # via the CLI prints `export OP_SESSION_*=...` for us to eval. Either
          # way a refused or cancelled signin exits nonzero and aborts the run.
          eval "$(op signin)"
          echo "--> okay, signed in" >&2
        fi

        # Reconciles the PIV applet's management key to be non-default,
        # PIN-protected, and TDES.
        #
        # TODO(eliza): Unfortunately, `age-plugin-yubikey` cannot authenticate
        # with AES management keys, which are the default on firmware >=5.7.
        # See https://github.comstr4d/age-plugin-yubikey/issues/92.
        # This is a shame. When upstream supports AES, remove the `-a TDES` pin.
        #
        # This script can automatically rotate the key when the current key is
        # factory-default (well-known bytes) or PIN-protected (ykman reads it
        # back after PIN verification). A non-default, unprotected, non-TDES key
        # cannot be reconciled without knowing the key, so we give up and hope
        # the user remembers it.
        ensure_mgmt_key() {
          local piv_info
          piv_info="$(ykman --device "$SERIAL" piv info)"
          if grep -q "Using default Management key" <<< "$piv_info"; then
            echo "PIV: rotating the factory management key to a random PIN-protected TDES key" >&2
            echo "     (enter the PIV PIN when prompted)..." >&2
            ykman --device "$SERIAL" piv access change-management-key -a TDES --generate --protect
          elif ! grep -q "Management key algorithm:[[:space:]]*TDES" <<< "$piv_info"; then
            if grep -q "protected by PIN" <<< "$piv_info"; then
              echo "PIV: management key is not TDES (currently required by age-plugin-yubikey)" >&2
              echo "     re-rotating (enter the PIV PIN when prompted)..." >&2
              ykman --device "$SERIAL" piv access change-management-key -a TDES --protect
            else
              echo "error: the PIV management key is neither factory-default nor PIN-protected," >&2
              echo "and is not TDES, required by age-plugin-yubikey" >&2
              echo "(see https://github.com/str4d/age-plugin-yubikey/issues/92)" >&2
              echo "" >&2
              echo "I can't fix this without knowing the current key. Run" >&2
              echo "  ykman piv access change-management-key -a TDES --protect -m <current-key>" >&2
              echo "and then hopefully re-running his script will work?" >&2
              exit 1
            fi
          fi
        }

        # Reconciles the age identity across the Yubikey, the repo, and the
        # script: generating an identity on the device if none exists,
        # (re)builds the stub file, writes the recipient file, and leaves the
        # validated recipient and slot in AGE_RECIPIENT / AGE_SLOT. This is
        # called both when provisioning for the first time and when resuming a
        # partially completed provisioning attempt.
        #
        # Rather than having age-plugin-yubikey write the stub to a file in the
        # repo, we generate the stub to a temp file and only move it into the
        # repo if the plugin exits non-zeroly. An earlier version of this script
        # didn't do that, and hilarity ensued when a failed generation left
        # behind an empty stub file, which a subsequent provisioning attempt
        # took as proof that it had completed previously. Aren't shell scripts
        # fun?
        ensure_age_identity() {
          local tmp
          if [ -s "$AGE_STUB" ]; then
            echo "age: identity stub $AGE_STUB already exists, nothing to do here." >&2
          elif [ -n "$(age-plugin-yubikey --list --serial "$SERIAL" 2>/dev/null)" ]; then
            # An identity exists on-device but the stub doesn't. Presumably this
            # is because a previous run of this script died. Rregenerate the
            # stub from the existing on-device key rather than burning another
            # keyslot.
            echo "age: device has an age identity, but no stub file exists. regenerating..." >&2
            tmp="$(mktemp "$AGE_STUB.XXXXXX")"
            age-plugin-yubikey --identity --serial "$SERIAL" > "$tmp"
            mv "$tmp" "$AGE_STUB"
            echo "--> done!" >&2
          else
            # Generation authenticates with the management key, so ensure it's
            # correct first.
            ensure_mgmt_key
            echo "age: generating age identity (enter the PIV PIN and touch when prompted)" >&2
            # No --slot: the plugin takes the first free PIV retired slot.
            # Its prompts go to the tty, not stdout, so capturing stdout
            # is safe. The PIN it asks for is the PIV PIN.
            #
            # EXTREMELY SERIOUS WARNING: to other uses of the PIV applet:
            # firmware 5.7+ can hold ED25519/X25519 keys in PIV slots, but
            # having such a key in ANY slot makes age-plugin-yubikey break
            # (see https://github.com/str4d/age-plugin-yubikey/issues/185).
            #
            # Therefore, until upstream fixes this, ABSOLUTELY NO ED25519/X25519
            # PIV KEYS. Luckily, we aren't using PIV for SSH identities, so we
            # don't need them. But still. Don't do it.
            tmp="$(mktemp "$AGE_STUB.XXXXXX")"
            age-plugin-yubikey --generate \
              --serial "$SERIAL" \
              --name "''${YUBIKEY_LABEL:-yubikey-$SERIAL}" \
              --pin-policy once \
              --touch-policy cached \
              > "$tmp"
            mv "$tmp" "$AGE_STUB"
            echo "--> done!" >&2
          fi
          # The stub's metadata header records the recipient and the slot.
          # the "Slot:" match relies on it appearing only on the
          # "Serial: ..., Slot: N" line.
          AGE_RECIPIENT="$(sed -n 's/^#.*Recipient: *//p' "$AGE_STUB" | head -n 1)"
          AGE_SLOT="$(sed -n 's/^#.*Slot: *//p' "$AGE_STUB" | head -n 1)"
          case "$AGE_RECIPIENT" in
            age1yubikey1*) ;;
            *)
              echo "error: no age recipient parsed from $AGE_STUB (got '$AGE_RECIPIENT')" >&2
              echo "did age-plugin-yubikey's stub header format change?" >&2
              exit 1
              ;;
          esac
          case "$AGE_SLOT" in
            ""|*[!0-9]*)
              echo "error: no PIV slot parsed from $AGE_STUB (got '$AGE_SLOT')" >&2
              echo "did age-plugin-yubikey's stub header format change?" >&2
              exit 1
              ;;
          esac
          printf '%s\n' "$AGE_RECIPIENT" > "$AGE_RECIPIENT_FILE"
          emit_file "$AGE_STUB"
          emit_file "$AGE_RECIPIENT_FILE"
        }

        echo "preflight: is YubiKey $SERIAL already provisioned?" >&2
        if op item get "$KEY_ITEM" --vault "$VAULT" > /dev/null 2>&1; then
          echo "--> yes, '$KEY_ITEM' already exists in vault '$VAULT'; making sure the repo files are all here..." >&2
          if [ ! -f "$REPO_PUBKEY" ]; then
            mkdir -p "$AUTHORIZED_KEYS_DIR"
            op read "op://$VAULT/$KEY_ITEM/SSH key/public key" > "$REPO_PUBKEY"
            emit_file "$REPO_PUBKEY"
          fi
          if [ ! -s "$AGE_RECIPIENT_FILE" ] || [ ! -s "$AGE_STUB" ]; then
            # If these files are empty, a previous version of this script has
            # died tragically, so rebuild the stub.
            ensure_age_identity
            # And, since the stub had to be rebuilt, the escrowed age fields are
            # probably also messed up, so fix them too
            op item edit "$KEY_ITEM" --vault "$VAULT" \
              "age.recipient[text]=$AGE_RECIPIENT" \
              "age.slot[text]=$AGE_SLOT" \
              "age.identity[file]=$AGE_STUB" > /dev/null
            echo "--> refreshed the age fields in '$KEY_ITEM'" >&2
          fi
          if [ ! -f "$PAM_CRED_FILE" ]; then
            echo "note: the PAM U2F credential $PAM_CRED_FILE is missing." >&2
            echo "I can't restore it, since re-enrolling needs the physical key." >&2
          fi
          if [ ! -f "$KEYFILE" ]; then
            echo "note: $KEYFILE isn't on this machine." >&2
            echo "you can restore the keyfile and its passphrase from '$KEY_ITEM' / '$PASS_ITEM'." >&2
          fi
          echo "all done; everything is up to date!"
          exit 0
        fi
        echo "--> not yet, let's fix that" >&2

        # Resumed runs reuse the existing passphrase item: once ssh-keygen may
        # have consumed the generated passphrase, the item is the only copy and
        # is never rolled back.
        if op item get "$PASS_ITEM" --vault "$VAULT" > /dev/null 2>&1; then
          echo "SSH: using already-escrowed passphrase from 1Password '$PASS_ITEM' (resumed run)" >&2
          PASS_ITEM_ID="$(op item get \
            "$PASS_ITEM" \
            --vault "$VAULT" \
            --format json | jq -r .id)"
        else
          echo "SSH: generating 1Password ssh key passphrase item..." >&2
          # A word-based passphrase (6 words from the EFF long list, ~77 bits).
          # The 1Password GUI can also generate word-based passphrases, but the
          # CLI's --generate-password only does character-class recipes, so we
          # use xkcdpass instead.
          NEW_PASSPHRASE="$(xkcdpass --numwords 6 --delimiter -)"
          if ! PASS_ITEM_ID="$(op item create \
            --category Password \
            --title "$PASS_ITEM" \
            --vault "$VAULT" \
            --tags yubikey,ssh \
            "password=$NEW_PASSPHRASE" \
            "YubiKey.serial[text]=$SERIAL" \
            --format json | jq -r .id)"
          then
            echo "error: creating '$PASS_ITEM' failed." >&2
            echo "nothing has been created yet, so it's safe to just re-run to retry." >&2
            exit 1
          fi
        fi
        # Read the passphrase back from 1Password rather than using the local
        # value, so that keygen then always consumes the escrowed copy. This
        # way, a write-time mangling would fail loudly here instead of quietly
        # encrypting the keyfile to a passphrase that isn't the escrowed one.
        PASSPHRASE="$(op read "op://$VAULT/$PASS_ITEM_ID/password")"
        echo "--> done!" >&2

        if [ -f "$KEYFILE" ]; then
          echo "SSH: key $KEYFILE already exists, nothing to do here." >&2
        else
          echo "SSH: generating SSH key (touch the YubiKey when it blinks)" >&2
          mkdir -p "$HOME/.ssh"
          ssh-keygen \
            -t ed25519-sk \
            -O write-attestation="$ATTESTATION" \
            -O user="$KEY_USER" \
            -f "$KEYFILE" \
            -C "$KEY_USER@yk''${SERIAL}.$SSH_COMMENT_DOMAIN" \
            -N "$PASSPHRASE"
          echo "--> done!" >&2
        fi
        # The keyfile may predate this run (a resumed run, or a stray manual
        # ssh-keygen), in which case nothing guarantees it was encrypted to the
        # escrowed passphrase. Check now, at provisioning time, so we don't have
        # to discover this later when actually trying to use the escrowed
        # passphrase. For sk keys, `-y` reads only the handle file (the public
        # half is stored in it), so this needs neither the YubiKey nor a touch.
        echo "SSH: verifying that the escrowed passphrase opens $KEYFILE..." >&2
        if ! ssh-keygen -y -P "$PASSPHRASE" -f "$KEYFILE" > /dev/null; then
          echo "error: the escrowed passphrase in '$PASS_ITEM' does not open $KEYFILE." >&2
          echo "this keyfile was probably created outside this script. either move it" >&2
          echo "aside and re-run to generaet a fresh key, or manually fix the escrowed" >&2
          echo "passphrase item to match the keyfile." >&2
          exit 1
        fi
        echo "--> escrow verified" >&2
        mkdir -p "$AUTHORIZED_KEYS_DIR"
        cp "$KEYFILE.pub" "$REPO_PUBKEY"
        emit_file "$REPO_PUBKEY"

        # --- PIV access credentials, before the age identity is minted ---
        #
        # The PIV applet has its own PIN/PUK/management key, all with well-known
        # factory defaults (PIN 123456, PUK 12345678, management key
        # 0102...0708). These are entirely separate from the FIDO2 PIN set
        # below. Make sure that we set an un-default PIN before trying to
        # generate an age identity, since that will prompt for the PIN.
        #
        # The factory PUK is a security hole, so set a new one here. The PUK
        # unblocks the PIN, so anyone with physical access the key could set
        # their own PIN and then *use* the age identity. It is replaced with a
        # generated value escrowed in 1Password (on the passphrase item, which
        # already exists by this point). The PUK is escrowed BEFORE it is
        # applied so a provisioning failure doesn't leave the key with a PUK set
        # that nobody actually knows.
        #
        # Detection uses `ykman piv info`'s metadata-based warnings
        # ("WARNING: Using default PIN!" etc., firmware 5.3+), so resumed
        # runs never re-attempt a change against already-rotated
        # credentials (which would burn retries).
        PIV_INFO="$(ykman --device "$SERIAL" piv info)"
        echo "PIV: is the PIN still factory-default?" >&2
        if grep -q "Using default PIN" <<< "$PIV_INFO"; then
          echo "--> yes; changing it now (enter the memorized PIN when prompted)" >&2
          ykman --device "$SERIAL" piv access change-pin --pin 123456
        else
          echo "--> no, already changed" >&2
        fi
        echo "PIV: is the PUK still factory-default?" >&2
        if grep -q "Using default PUK" <<< "$PIV_INFO"; then
          echo "--> yes; generating and escrowing a PUK..." >&2
          # Idempotent escrow-then-apply: reuse an already-escrowed PUK if
          # a previous run got that far, mirroring the passphrase item.
          if ! PUK="$(op read "op://$VAULT/$PASS_ITEM_ID/PIV/puk" 2>/dev/null)"; then
            # The `|| true` swallows tr's SIGPIPE status when head exits
            # after 8 digits, which pipefail would otherwise turn into a
            # script abort.
            NEW_PUK="$({ tr -dc '0-9' < /dev/urandom || true; } | head -c 8)"
            op item edit "$PASS_ITEM_ID" "PIV.puk[password]=$NEW_PUK" > /dev/null
            PUK="$(op read "op://$VAULT/$PASS_ITEM_ID/PIV/puk")"
          fi
          ykman --device "$SERIAL" piv access change-puk --puk 12345678 --new-puk "$PUK"
        else
          echo "--> no, already changed" >&2
        fi

        # this will also ensure the management key is correct.
        ensure_age_identity

        # Set a FIDO2 pin after ssh keygen, if it isn't already set. Once a
        # FIDO2 PIN exists, credential creation prompts for it. Waiting until
        # after we've generated the SSH key prevents the user from having to
        # enter it when the keys are generated, making things slightly more
        # convenient. This doesn't actually affect the behavior when keys are
        # used, but means you have to type the pin slightly fewer times while
        # running the script.
        echo "FIDO2: checking for a FIDO2 PIN..." >&2
        if ykman --device "$SERIAL" fido info | grep -q "PIN:[[:space:]]*Not set"; then
          echo "--> not set; setting it now (use the memorized PIN)" >&2
          ykman --device "$SERIAL" fido access change-pin
        else
          echo "--> already set" >&2
        fi

        # Generate the PAM credential, if it doesn't already exist, and turn it
        # into an agenix secret. The secret holds only the bare credential (no
        # username prefix), because the authfile generator adds the user and
        # joins the credentials together when the Nix config is evaluated.
        if [ -f "$PAM_CRED_FILE" ]; then
          echo "PAM: credential $PAM_CRED_FILE already exists, nothing to do here." >&2
        else
          echo "PAM: registering a PAM U2F credential for $ORIGIN (PIN + touch when prompted)..." >&2
          PAM_CRED="$(pamu2fcfg \
            --nouser \
            --origin "$ORIGIN" \
            --appid "$ORIGIN" \
            --pin-verification)"
          PAM_CRED="''${PAM_CRED#:}"
          mkdir -p "$PAM_CREDENTIALS_DIR"
          CRED_TMP="$(mktemp)"
          trap 'rm -f "$CRED_TMP"' EXIT
          printf '%s\n' "$PAM_CRED" > "$CRED_TMP"
          # `-i` requires a regular file (it checks -f, so process substitution
          # won't do). Encryption targets the master identities, so no decryption
          # or host declaration is needed at this point.
          agenix edit -i "$CRED_TMP" "$PAM_CRED_FILE"
          rm -f "$CRED_TMP"
          emit_file "$PAM_CRED_FILE"
          # The generated authfile (if any) is now stale; delete it so the next
          # `agenix generate` rebuilds it from all the credentials.
          if [ -f "$GENERATED_SECRETS_DIR/$PAM_AUTHFILE_SECRET.age" ]; then
            rm "$GENERATED_SECRETS_DIR/$PAM_AUTHFILE_SECRET.age"
            echo "--> deleted stale generated authfile; re-run 'agenix generate' + 'agenix rekey'" >&2
          fi
          echo "--> done!" >&2
        fi

        echo "escrow: creating 1Password item for YubiKey $SERIAL..." >&2
        YK_INFO="$(ykman --device "$SERIAL" info)"
        DEVICE_TYPE="$(sed -n 's/^Device type: *//p' <<< "$YK_INFO")"
        FIRMWARE="$(sed -n 's/^Firmware version: *//p' <<< "$YK_INFO")"
        # `ssh-keygen -l` output is "<bits> <fingerprint> <comment> (<type>)";
        # keep just the fingerprint.
        FINGERPRINT="$(ssh-keygen -lf "$KEYFILE.pub" | cut -d ' ' -f 2)"

        EXTRA_FIELDS=()
        if [ -n "''${YUBIKEY_LABEL:-}" ]; then
          EXTRA_FIELDS+=("label[text]=$YUBIKEY_LABEL")
        fi

        if ! KEY_ITEM_ID="$(op item create \
          --category "Secure Note" \
          --title "$KEY_ITEM" \
          --vault "$VAULT" \
          --tags yubikey,ssh,age,pam \
          "SSH key.public key[text]=$(cat "$KEYFILE.pub")" \
          "SSH key.fingerprint[text]=$FINGERPRINT" \
          "SSH key.private keyfile[file]=$KEYFILE" \
          "SSH key.attestation[file]=$ATTESTATION" \
          "age.recipient[text]=$AGE_RECIPIENT" \
          "age.slot[text]=$AGE_SLOT" \
          "age.identity[file]=$AGE_STUB" \
          "YubiKey.serial[text]=$SERIAL" \
          "YubiKey.device[text]=$DEVICE_TYPE" \
          "YubiKey.firmware[text]=$FIRMWARE" \
          "related.passphrase item[text]=$PASS_ITEM_ID" \
          "''${EXTRA_FIELDS[@]}" \
          --format json | jq -r .id)"
        then
          echo "error: creating '$KEY_ITEM' failed." >&2
          echo "everything else has already been generated and escrowed, so it's safe to just re-run to retry." >&2
          exit 1
        fi
        echo "--> done!" >&2

        # Try to link the passphrase item to the key item in 1Password.
        if ! op item edit "$PASS_ITEM_ID" \
          "related.key item[text]=$KEY_ITEM_ID" > /dev/null
        then
          # I dunno why that didn't work, but it's fine, I guess.
          echo "warning: failed to link '$PASS_ITEM' -> '$KEY_ITEM' in 1Password" >&2
          echo "this is not a big deal, since you can do that manually..." >&2
        fi

        echo "Provisioned YubiKey $SERIAL ($DEVICE_TYPE)''${YUBIKEY_LABEL:+ [$YUBIKEY_LABEL]}:"
        echo "  ssh private key: $KEYFILE"
        echo "  ssh public key:  $REPO_PUBKEY"
        echo "  fingerprint:     $FINGERPRINT"
        echo "  age identity:    $AGE_STUB (PIV slot $AGE_SLOT)"
        echo "  age recipient:   $AGE_RECIPIENT_FILE"
        echo "  pam u2f:         $PAM_CRED_FILE (credential for $ORIGIN)"
        echo "  1Password:       escrowed in vault '$VAULT'"
        echo "    ssh key:       '$KEY_ITEM' ($KEY_ITEM_ID)"
        echo "    ssh pass:      '$PASS_ITEM' ($PASS_ITEM_ID)"
        echo
        echo "Next: 'agenix generate && agenix rekey', then commit the new files under secrets/."
      '';
    };

  # ykrevoke: revoke an enrolled YubiKey's in-repo artifacts.
  #
  # The inverse of ykprovision, for when a key is lost, stolen, or retired. The
  # serial of the key to revoke is required as an argument, because revocation
  # obviously must work without the key present..."the key is gone" is the main
  # reason we're running this!
  #
  # All this script does is delete the artifacts in this repo that correspond to
  # the revoked key: the SSH pubkey, age recipient/identity stub, and PAM U2F
  # credential are removed, plus the generated PAM authfile. Deleting the
  # generated authfile ensures that `agenix generate` will regenerate it when
  # redeploying the config. Agenix only re-evaluates generators when their
  # output file is missing or when dependencies have changed, and it doesn't
  # detect removing a dependency, so we have to delete it here too.
  #
  # Everything the repo can't reach (GitHub, 1Password, deployed hosts, the
  # physical key) is printed as a checklist at the end.
  ykrevoke = with pkgs; writeShellApplication {
    name = "ykrevoke";
    runtimeInputs = [ coreutils git ];
    text = ''
      AUTHORIZED_KEYS_DIR=${escapeShellArg authorizedKeysDir}
      MASTER_IDENTITIES_DIR=${escapeShellArg masterIdentitiesDir}
      PAM_CREDENTIALS_DIR=${escapeShellArg pam_u2fCredentialsDir}
      PAM_AUTHFILE_SECRET=${escapeShellArg pam_u2fAuthfileSecret}
      GENERATED_SECRETS_DIR=${escapeShellArg generatedSecretsDir}
      SSH_KEYFILE_PREFIX=${escapeShellArg sshKeyfilePrefix}

      ${confirmOrAbort}

      usage() {
        echo "usage: ykrevoke <serial>" >&2
        echo >&2
        echo "enrolled serials:" >&2
        FOUND=0
        for f in "$AUTHORIZED_KEYS_DIR/$SSH_KEYFILE_PREFIX"*.pub; do
          [ -e "$f" ] || continue
          s="''${f##*/}"
          s="''${s#"$SSH_KEYFILE_PREFIX"}"
          echo "  ''${s%.pub}" >&2
          FOUND=1
        done
        if [ "$FOUND" = 0 ]; then
          echo "  (none found in $AUTHORIZED_KEYS_DIR/)" >&2
        fi
      }

      if [ "$#" -ne 1 ]; then
        usage
        exit 1
      fi
      SERIAL="$1"
      case "$SERIAL" in
        (*[!0-9]*|"")
          echo "error: '$SERIAL' doesn't look like a YubiKey serial number" >&2
          usage
          exit 1
          ;;
      esac

      ${checkFlakeRoot}

      REPO_PUBKEY="$AUTHORIZED_KEYS_DIR/''${SSH_KEYFILE_PREFIX}''${SERIAL}.pub"
      AGE_STUB="$MASTER_IDENTITIES_DIR/yubikey-''${SERIAL}.txt"
      AGE_RECIPIENT_FILE="$MASTER_IDENTITIES_DIR/yubikey-''${SERIAL}.pub"
      PAM_CRED_FILE="$PAM_CREDENTIALS_DIR/yubikey-''${SERIAL}.age"
      AUTHFILE="$GENERATED_SECRETS_DIR/$PAM_AUTHFILE_SECRET.age"

      TARGETS=()
      for f in "$REPO_PUBKEY" "$AGE_STUB" "$AGE_RECIPIENT_FILE" "$PAM_CRED_FILE"; do
        if [ -e "$f" ]; then
          TARGETS+=("$f")
        fi
      done
      if [ "''${#TARGETS[@]}" -eq 0 ]; then
        echo "nothing to do: no artifacts for YubiKey $SERIAL exist in the repo." >&2
        usage
        exit 1
      fi

      echo "revoking YubiKey $SERIAL removes:" >&2
      for f in "''${TARGETS[@]}"; do
        echo "  $f" >&2
      done
      if [ -f "$AUTHFILE" ]; then
        echo "  $AUTHFILE (stale generated authfile; regenerate after)" >&2
      fi
      echo "--> continue?" >&2
      confirm_or_abort

      # `git rm` (rather than plain rm) so the deletion is visible to pure
      # flake eval even before it is committed; plain rm suffices for
      # untracked files, which eval never saw in the first place.
      revoke_file() {
        if git ls-files --error-unmatch "$1" > /dev/null 2>&1; then
          git rm --quiet --force "$1"
        else
          rm -f "$1"
        fi
        echo "--> removed $1" >&2
      }

      for f in "''${TARGETS[@]}"; do
        revoke_file "$f"
      done
      if [ -f "$AUTHFILE" ]; then
        revoke_file "$AUTHFILE"
      fi

      echo
      echo "In-repo revocation of YubiKey $SERIAL is done. The rest is on you:"
      echo
      echo " 1. Regenerate and redeploy secrets:"
      echo "        agenix generate && agenix rekey"
      echo "    then commit and rebuild every pam_u2f host."
      echo " 2. REMOVE THE SSH KEY FROM GITHUB, and from anywhere else its "
      echo "    pubkey was uploaded."
      echo " 3. 1Password: leave 'YubiKey $SERIAL' and its passphrase item"
      echo "    alone, or archive them; the escrowed handle is useless without"
      echo "    the physical key, and deleting the items destroys the record"
      echo "    of what was escrowed."
      echo " 4. Delete ~/.ssh/''${SSH_KEYFILE_PREFIX}''${SERIAL}* from any"
      echo "    machines the handles were present on. This is not security"
      echo "    critical but seems good to do."
      echo " 5. If this key's age recipient was used as an agenix master"
      echo "    identity, ciphertexts in git history remain decryptable by"
      echo "    whoever holds the physical key (given its PIN): if the key is"
      echo "    compromised rather than retired, rotate those secrets."
      echo " 6. If you still have the physical key, 'ykman config reset' wipes it."
    '';
  };
in
{
  options.profiles.yubikey = {
    enable = mkEnableOption "yubikey config";

    # The provisioning scripts are enabled separately, since they pull in a
    # bunch of dependencies, and are not needed on every host that uses
    # yubikey auth.
    provisioning.enable = mkEnableOption ''
      the `ykprovision` and `ykrevoke` scripts, for enrolling YubiKeys into
      (and revoking them from) the auth scheme.
    '';

    pam_u2f = {
      enable = mkEnableOption ''
        pam_u2f authentication (YubiKey + PIN + touch) using the per-key
        credentials generated by `ykprovision`.
      '';

      lockOnUnplug = mkEnableOption ''
        automatically locking every logged in session when an enrolled YubiKey
        is unplugged.
      '';

      control = mkOption {
        type = types.enum [ "required" "requisite" "sufficient" "optional" ];
        default = "sufficient";
        description = ''
          PAM control mode for pam_u2f. `sufficient` means YubiKey + PIN +
          touch works in place of a password, with password fallback (no
          lockout risk).

          Switch to `required` for true 2FA, with the password AND YubiKey
          always required. Before doing so, make sure a backup key is enrolled
          and reachable, and remember this does not cover FDE/initrd unlock.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Base config with nothing else enabled: just the necessary dependencies for
    # day-to-day YubiKey use.
    {
      # Provides `ykman`, pcscd, and the udev rules. These are required both
      # for daily YubiKey use and for the provisioning script.
      programs.yubikey-manager.enable = true;
      # Generates notifications when the YubiKey is asking to be touched. By
      # default, send these to libnotify for desktop use.
      programs.yubikey-touch-detector = {
        enable = mkDefault true;
        libnotify = mkDefault true;
      };

      # /dev/yubikey/<serial> symlinks used as presence markers for attached
      # YubiKeys. We create a symlink per key, named using the device's serial
      # number. Consumers can glob the directory to learn which enrolled keys
      # are physically present without any device I/O (which is slow and
      # contends with pcscd/scdaemon). Presently, this is only used for
      # selecting which SSH key to offer and to use for Git commitsigning.
      #
      # Requires the serial to be visible in the USB descriptor
      # (SERIAL_USB_VISIBLE), which ykprovision's OTP phase configures.
      services.udev.packages =
        let
          # When ykman prints serials, they are displayed without leading
          # zeroes, but udev's USB descriptor will include them. This IMPORT
          # helper strips that so symlink names match ykman's formatting for
          # serials. IMPORT{program} is evaluated as a match, so a key with a
          # hidden or malformed serial simply gets no symlink.
          normalizeSerial = pkgs.writeShellScript "yk-serial-normalize" ''
            ${yubikeysLib.usb.serialFunctions}
            s="$(normalize_yk_serial "''${1:-}")" || exit 1
            echo "YK_SERIAL=$s"
          '';
          devYubikeysRules = pkgs.writeTextFile {
            name = "yubikey-udev-rules";
            text =
              ''
                SUBSYSTEM=="usb", \
                  ATTR{idVendor}=="${yubicoVid}", \
                  ATTR{serial}=="?*", \
                  IMPORT{program}="${normalizeSerial} $attr{serial}", \
                  SYMLINK+="yubikey/$env{YK_SERIAL}"
              '';
            destination = "/etc/udev/rules.d/50-yubikey.rules";
          };
        in
        [ devYubikeysRules ];
    }
    # If provisioning.enable = true, also include the `ykprovision` and
    # `ykrevoke` scripts.
    (mkIf cfg.provisioning.enable {
      # ensure that the global 1password CLI is present. the provisioning script
      # relies on this but cannot depend on it directly due to Some Kind of
      # Reason.
      programs._1password.enable = true;
      environment.systemPackages = [ ykprovision ykrevoke ];
    })
    # PAM-U2F auth config.
    (mkIf cfg.pam_u2f.enable (
      let
        # Per-key credentials discovered from the repo at eval time. The
        # dependency list for the authfile generator is automatically determined
        # based on which credential secrets are in the repo.
        credsPath = ../../.. + "/${pam_u2fCredentialsDir}";
        credFilenames = optionals (builtins.pathExists credsPath)
          (filter (hasSuffix ".age") (attrNames (builtins.readDir credsPath)));
        secretName = f: "pam-u2f-" + (removeSuffix ".age" f);
        # Serials of the enrolled keys. This is determined from the list of
        # actual PAM U2F credentials, rather than the list in
        # `lib/yubikeys.nix`, so that we *only* care about the ones actually
        # used for pam-u2f, and not keys that are only used for SSH. This does
        # not actually matter, since all my keys are enrolled for both,
        # but...let's do the more correct thing just in case.
        serials = map
          (f: removePrefix "yubikey-" (removeSuffix ".age" f))
          credFilenames;
      in
      {
        age.secrets =
          let
            # generate agenix `intermediary` secrets for each U2F key
            mkSecret = f:
              let
                name = secretName f;
                secret = {
                  rekeyFile = credsPath + "/${f}";
                  intermediary = true;
                };
              in
              nameValuePair name secret;
            credSecrets = map mkSecret credFilenames;
            authfileSecret = {
              ${pam_u2fAuthfileSecret} = {
                generator = {
                  dependencies = map
                    (f: config.age.secrets.${secretName f})
                    credFilenames;
                  # Deps are decrypted with the master identity during
                  # `agenix generate` and joined into pam_u2f's one-line format:
                  # `user:cred1:cred2:...`. Credential order follows readDir
                  # (lexicographic by serial), so output is deterministic.
                  script = { lib, decrypt, deps, ... }:
                    let
                      decryptCred = dep: ''
                        cred="$(${decrypt} ${lib.escapeShellArg dep.file} | tr -d '\n')" || exit 1
                        if [ -z "$cred" ]; then
                          echo "error: empty PAM credential decrypted from ${dep.file}" >&2
                          exit 1
                        fi
                        printf ':%s' "$cred"
                      '';
                      decryptCreds = lib.concatMapStrings decryptCred deps;
                    in
                    ''
                      printf '%s' ${lib.escapeShellArg user}
                      ${decryptCreds}
                      echo
                    '';
                };
              };
            };
          in
          listToAttrs credSecrets // authfileSecret;

        assertions = [
          {
            assertion = credFilenames != [ ];
            message = ''
              profiles.yubikey.pam_u2f is enabled, but no credential files
              exist in ${pam_u2fCredentialsDir}/. The generated authfile
              would contain no credentials, so pam_u2f could never succeed
              (and with control = "required", would lock out local auth).
              You must first enroll at least one yubikey with `ykprovision`!
            '';
          }
        ];

        # `security.pam.u2f.enable` adds pam_u2f to every PAM service's
        # auth stack by default. For sshd this is, pretty obviously, never
        # useful, since the YubiKey would have to be plugged into the server in
        # order to be used to authenticate an SSH connection. And, if control =
        # "required"  this is actively dangerous, since it makes it impossible
        # to SSH into a server unless your yubikey is plugged in. Lol. Lmao.
        security.pam.services.sshd.u2fAuth = false;

        security.pam.u2f = {
          enable = true;
          control = cfg.pam_u2f.control;
          settings = {
            # Must match the origin baked into the credentials by ykprovision
            # (same `pamOrigin` binding above). appid is set explicitly, because
            # some pam_u2f versions have mishandled it when it differed from
            # origin, and the default only covers credentials from old pamu2fcfg
            # versions.
            origin = pamOrigin;
            appid = pamOrigin;
            authfile = config.age.secrets.${pam_u2fAuthfileSecret}.path;
            # The credentials are generated with `pamu2fcfg --pin-verification`,
            # so enforce it module-side too.
            pinverification = 1;
            # Prompt a reminder when a touch is expected.
            cue = true;
            # debug = true;
            # debug_file = "/var/log/pam_u2f_debug.log";
          };
        };

        # sadly, GDM's `gdm-fingerprint` worker can race with `gdm-password`,
        # which is what pam-u2f hangs off of, and can block session startup when
        # logging in with the yubikey. so, turn off fprintd to make that work
        # nicer.
        services.fprintd.enable = false;

        # Lock local graphical sessions when the last enrolled YubiKey is
        # unplugged.
        #
        # This adds a udev rule that listens for removal events for USB devices
        # that have Yubikey VID/PIDs, and runs a script which checks for the
        # presence of any enrolled yubikey in sysfs and locks any graphical user
        # sessions if no enrolled yubikeys are present. This way, if I'm
        # provisioning a new yubikey and remove it, the system doesn't lock, and
        # if multiple yubikeys are present, the system only locks when they're
        # all removed.
        services.udev.packages = mkIf cfg.pam_u2f.lockOnUnplug (
          let
            # A shell script run when a yubikey device is unplugged that checks
            # if it's the last enrolled key, and then locks user sessions as
            # appropriate.
            lockScript = pkgs.writeShellApplication {
              name = "yubikey-lock-sessions";
              runtimeInputs = with pkgs; [ systemd coreutils ];
              text = ''
                ${yubikeysLib.usb.serialFunctions}

                # If any enrolled key is still plugged in, do nothing. sysfs
                # is authoritative here: the just-removed device is already
                # gone from it by the time this remove-triggered RUN fires.
                for present in $(sysfs_yk_serials); do
                  for enrolled in ${escapeShellArgs serials}; do
                    if [ "$present" = "$enrolled" ]; then
                      exit 0
                    fi
                  done
                done

                # No enrolled key remains: lock local graphical sessions.
                loginctl list-sessions --no-legend --no-pager \
                  | while read -r id _rest; do
                  # Filter only sessions which are local, graphical user
                  # sessions (Class=user, Type=wayland or Type=x11, Remote=no).
                  # This way, we don't lock SSH sessions, which are not
                  # authenticated by a locally connected yubikey, or remote
                  # desktop sessions. I'm not actually using any kind of remote
                  # desktop yet, but it's nice to not break that later.
                  class="$(loginctl show-session "$id" --property Class --value)"
                  type="$(loginctl show-session "$id" --property Type --value)"
                  remote="$(loginctl show-session "$id" --property Remote --value)"
                  if [ "$class" = user ] && [ "$remote" = no ] \
                    && { [ "$type" = wayland ] || [ "$type" = x11 ]; }; then
                    loginctl lock-session "$id"
                  fi
                done
              '';
            };

            # The actual rules file. Matches the removal of any Yubico
            # USB device. Sadly, udev remove events don't have serial numbers
            # (including the one we set up via YK_SERIAL), so we instead rely
            # on the locking script to sort out whether the unplugged device was
            # actually the one that authed the session or not. Oh well.
            lockRules = pkgs.writeTextFile {
              name = "yubikey-lock-udev-rules";
              destination = "/etc/udev/rules.d/70-yubikey-lock.rules";
              text = ''
                ACTION=="remove", \
                  SUBSYSTEM=="usb", \
                  ENV{DEVTYPE}=="usb_device", \
                  ENV{PRODUCT}=="${yubicoVid}/*", \
                  RUN+="${getExe lockScript}"
              '';
            };
          in
          [ lockRules ]
        );
      }
    ))
  ]);
}
