# Wake-on-LAN. See `lib/wol.nix` for the overall design.
#
# This module has three independent roles:
#
# - **Target**: enabled automatically on any host that `lib/wol.nix` names as
#   a target. Arms magic-packet wake on the NIC with the target's MAC, and
#   prepares the path from that NIC to the CPU (see `wakePathScript`).
# - **Relay**: enabled automatically on any host that `lib/wol.nix` lists in a
#   target's `relays`. Authorizes each such target's relay key for the `wol`
#   user, forced to broadcast that target's magic packet and nothing else.
# - **Client** (`profiles.wol.client.enable`): installs each target's relay
#   private key, readable by the login user, for the home-manager SSH config's
#   `ProxyCommand` to use.
{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.wol;
  wol = import ../../../lib/wol.nix { inherit lib; };
  # The login user that runs `ssh` on client hosts. See
  # `modules/nixos/default.nix`.
  user = "eliza";

  relayTargets = lib.filterAttrs
    (_: target: lib.elem config.networking.hostName target.relays)
    wol.targets;

  self = wol.targets.${config.networking.hostName} or null;

  # Run by udev when the wake NIC appears; the interface name is `$1`.
  #
  # Arms magic-packet wake, then walks from the NIC up to the root of the
  # device tree, enabling wakeup on every device that has the knob (USB hubs
  # and controllers, PCIe bridges) and forbidding D3cold on every PCI device.
  #
  # The D3cold part is the subtle one. In s2idle, the kernel otherwise puts the
  # NIC's PCI ancestors into D3cold, which takes the PCIe link down, so the wake
  # can only be signalled out-of-band on WAKE#. On hekate the board routes that
  # to an ACPI GPE (0x18) that the firmware never gave a handler, so the wake is
  # silently lost. With the link kept up (D3hot), the wake arrives as an in-band
  # PME message at the root port, which the OS handles natively. This was found
  # by experiment: with D3cold allowed, a magic packet set GPE 0x18's status bit
  # and nothing woke; with it forbidden, the system woke on the root port's PME
  # interrupt.
  #
  # Walking up from the NIC, rather than naming bus addresses, keeps this
  # correct when the NIC moves ports or PCI buses renumber.
  wakePathScript = pkgs.writeShellScript "wol-wake-path" ''
    PATH=${lib.makeBinPath (with pkgs; [ coreutils ethtool util-linux ])}
    iface="$1"
    log() { logger -t wol-wake-path -p "daemon.$1" -- "$iface: $2"; }

    if ! ethtool -s "$iface" wol g; then
      log err "failed to arm magic-packet wake; this host will not wake on LAN"
    fi

    dev="$(readlink -f "/sys/class/net/$iface/device")" || {
      log err "cannot resolve the device for $iface; wake path not configured"
      exit 1
    }
    pci_seen=0
    while [ "$dev" != /sys/devices ] && [ "$dev" != / ]; do
      if [ -e "$dev/power/wakeup" ]; then
        echo enabled > "$dev/power/wakeup" \
          || log err "failed to enable wakeup on $dev"
      fi
      if [ -e "$dev/d3cold_allowed" ]; then
        pci_seen=1
        echo 0 > "$dev/d3cold_allowed" \
          || log err "failed to forbid D3cold on $dev"
      fi
      dev="$(dirname "$dev")"
    done
    if [ "$pci_seen" -eq 0 ]; then
      log warning "no PCI devices above $iface; D3cold not restricted"
    fi
    log info "wake path configured"
  '';
in
with lib;
{
  options.profiles.wol = {
    client.enable = mkEnableOption ''
      installing the Wake-on-LAN relay keys for the targets in `lib/wol.nix`, so
      that `ssh <target>` can wake the target via its relay when off the LAN
    '';
  };

  config = mkMerge [
    (mkIf (self != null) (mkMerge [
      {
        services.udev.extraRules = ''
          ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="${toLower self.mac}", RUN+="${wakePathScript} %k"
        '';
      }
      (mkIf self.dedicatedNic {
        assertions = [{
          assertion = config.networking.networkmanager.enable;
          message = ''
            ${config.networking.hostName} has a dedicated Wake-on-LAN NIC in
            `lib/wol.nix`, which is brought up by a NetworkManager profile, but
            NetworkManager is not enabled.
          '';
        }];
        # Bring the link up, so the PHY stays powered and negotiated, without
        # giving the NIC any addresses or routes. NetworkManager's default for
        # `wake-on-lan` leaves the setting alone, so the udev rule above stays
        # its only owner.
        networking.networkmanager.ensureProfiles.profiles."wol-${config.networking.hostName}" = {
          connection = {
            id = "wol-${config.networking.hostName}";
            type = "ethernet";
            autoconnect = true;
          };
          ethernet.mac-address = self.mac;
          ipv4.method = "disabled";
          ipv6.method = "disabled";
        };
      })
    ]))

    (mkIf (relayTargets != { }) {
      assertions = mapAttrsToList
        (name: target: {
          assertion = target.relayKey.pubkey != null;
          message = ''
            ${config.networking.hostName} is the Wake-on-LAN relay for ${name},
            but ${toString target.relayKey.pubkeyFile} does not exist. Run
            `agenix generate` (with `profiles.wol.client.enable` set on at least
            one host, which declares the generator), then `agenix rekey`.
          '';
        })
        relayTargets;

      # A dedicated user, rather than the login user, because pam_rssh (see
      # `profiles/yubikey.nix`) accepts any key in the login user's
      # `authorized_keys` as a sudo credential, regardless of the key's
      # `restrict`/`command=` options. The relay key has no passphrase, so it
      # must not be in a sudoer's `authorized_keys`.
      users.users.wol = {
        isSystemUser = true;
        group = "wol";
        description = "Wake-on-LAN relay";
        # sshd runs forced commands through the user's shell, so this cannot
        # be `nologin`.
        useDefaultShell = true;
        openssh.authorizedKeys.keys = mapAttrsToList
          (_: target:
            let
              wake = "${pkgs.wakeonlan}/bin/wakeonlan -i ${target.broadcast} ${target.mac}";
            in
            ''restrict,command="${wake}" ${target.relayKey.pubkey}'')
          (filterAttrs (_: target: target.relayKey.pubkey != null) relayTargets);
      };
      users.groups.wol = { };
    })

    (mkIf cfg.client.enable {
      age.secrets = mapAttrs'
        (_: target: nameValuePair target.relayKey.secretName {
          inherit (target.relayKey) rekeyFile;
          generator.script = target.relayKey.generator;
          owner = user;
          mode = "0400";
        })
        wol.targets;
    })
  ];
}
