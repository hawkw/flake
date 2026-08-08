# The registry of enrolled YubiKey credentials, for use in Nix configs that need
# to reference them.
{ lib }:
{
  # Stuff for detecing attached YubiKeys as USB devices detection over USB,
  # shared by the udev rule and `ykprovision`
  # (modules/nixos/profiles/yubikey.nix) and the git signing-key selector
  # (modules/home/profiles/git.nix).
  usb = rec {
    # Yubico's USB vendor ID.
    vendorId = "1050";

    # Bash fragment defining the serial-handling shell functions, for
    # interpolation into the scripts named above.
    serialFunctions = ''
      # Prints the canonical decimal form of a YubiKey serial, stripping the
      # USB descriptor's zero-padding.
      normalize_yk_serial() {
        case "''${1:-}" in (*[!0-9]*|"") return 1;; esac
        echo "$((10#$1))"
      }

      # Enumerates the serials of attached YubiKeys, one per line, by
      # walking sysfs.
      sysfs_yk_serials() {
        local d
        for d in /sys/bus/usb/devices/*; do
          { [ -f "$d/idVendor" ] && [ -f "$d/serial" ]; } || continue
          [ "$(cat "$d/idVendor")" = "${vendorId}" ] || continue
          normalize_yk_serial "$(cat "$d/serial")" || continue
        done
      }
    '';
  };
  # Yubikey-backed ed25519-sk SSH keys.
  #
  # `ykprovision` (see `modules/nixos/profiles/yubikey.nix`) generates one
  # pubkey per provisioned YubiKey in secrets/authorized-keys/. These public
  # keys are referenced in both NixOS (for per-host `authorized_keys`) and
  # home-manager (for SSH `IdentityFile`s), so this file provides a single
  # definition of their location that both configs and the provisioning script
  # can all depend on, ensuring they all agree on where the pubkeys are located
  # and their names.
  ssh = rec {
    # Where the pubkeys live. The provisioning script's repo-relative
    # AUTHORIZED_KEYS_DIR is derived from this path, so they can't drift.
    pubkeyDir = ../secrets/authorized-keys;

    # Filename prefix for the SSH keyfiles. The device's serial number is
    # concatenated to this to form the actual base name for the file. The prefix
    # is defined here, as it is referenced in both this module and in the
    # provisioning script.
    keyfilePrefix = "id_ed25519_yk";

    # Basenames of the pubkey files (`id_ed25519_yk<serial>.pub`).
    pubkeyFilenames =
      let
        files = if builtins.pathExists pubkeyDir then builtins.readDir pubkeyDir else { };
        filenames = builtins.attrNames files;
      in
      (builtins.filter (lib.hasSuffix ".pub") filenames);

    # An attrset mapping each YubiKey serial to the corresponding SSH key. This
    # is used to look up the key corresponding to the currently attached device,
    # such as when selecting which key to use for Git signing based on which
    # YubiKey is present.
    #
    # Fields:
    #   privkeyFilename: basename of the private key handle file.
    #   pubkeyFilename: basename of the pubkey file in the repo.
    #   pubkey: the public key value itself.
    bySerial =
      let
        mkKey = (pubkeyFilename:
          let
            privkeyFilename = lib.removeSuffix ".pub" pubkeyFilename;
            pubkeyPath = pubkeyDir + "/${pubkeyFilename}";
            pubkey = lib.removeSuffix "\n" (builtins.readFile pubkeyPath);
            serial = lib.removePrefix keyfilePrefix privkeyFilename;
            keyattrs = { inherit privkeyFilename pubkeyFilename pubkey; };
          in
          lib.nameValuePair serial keyattrs
        );
        keys = (map mkKey pubkeyFilenames);
      in
      lib.listToAttrs keys;

    # Basenames of the corresponding private key handle files
    # (`id_ed25519_yk<serial>`). These, obviously, do not exist in the repo, but
    # are used to determine the paths that should be referenced in SSH configs
    # on the systems that actually have the keys.
    privkeyFilenames = lib.mapAttrsToList (_: key: key.privkeyFilename) bySerial;

    # The actual public key values, for use in `openssh.authorizedKeys.keys` and
    # friends.
    pubkeys = lib.mapAttrsToList (_: key: key.pubkey) bySerial;
  };
}
