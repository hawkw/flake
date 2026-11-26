# Wake-on-LAN, including a (somewhat convoluted) scheme for waking hosts from
# outside the LAN via SSH relays.
#
# A Wake-on-LAN magic packet is an Ethernet (layer 2) broadcast. This means
# that, when a client system that wants to wake a sleeping server is not on the
# same LAN as the server (in my case, when I'm connecting to my home network
# over a WireGuard VPN), there is no way to send a magic packet directly to the
# server's NIC.
#
# One potential solution to this is to use Wake-on-LAN on unicast activity
# (`u`), plus an ARP cache on an always-on system on the LAN that responds to
# ARP requests on the sleeping server's behalf. However, this requires that the
# NIC be capable of waking on unicast activity. It also requires that the *same*
# interface that one ultimately wishes to connect to be the same as the one that
# wakes the host (potentially an issue when the primary NIC(s) don't support
# WoL). It also means *any* unicast activity will wake the host, which may not
# be desirable if there's lots of stuff flying around on the LAN (i.e.
# prometheus scrapes...).
#
# Instead, this module implements a goofy scheme where always-on hosts on the
# same LAN as the target system act as *relays*, broadcasting a magic packet on
# a remote clients' behalf. a client's behalf. Clients request a relay send a
# magic packet over SSH, using a dedicated key with an `authorized_keys` entry
# which is restricted to running `wakeonlan` for a particular wake target.
# Multiple hosts on the LAN can act as relays, with the client attempting them
# in turn, so that the system can tolerate a relay outage.
#
# Thus, a system can be configured with any of the following three roles:
#
# - **Target** (`profiles.wakeOnLan.target`): a system which is woken remotely.
#   For systems configured as targets, this module ensures that the NIC
#   configured to receive the magic packet is able to wake the host from s2idle
#   sleep.
# - **Relay** (`profiles.wakeOnLan.relay.enable`): a system which relays WoL
#   magic packets. A system that enables the relay role will generate a `wol`
#   user, which has authorized_keys entries for each configured target, with a
#   forced command that sends the magic packet to the target.
# - **Client** (`profiles.wakeOnLan.client.enable`): a system which would like
#   to wake remote targets. For systems configured as clients, this module
#   generates a SSH private key, readable by the login user. This key is used by
#   the SSH `ProxyCommand` that `modules/home/ssh.nix` generates for each host
#   configured as a target..
#
# Systems configured as clients and relays find the set of targets find each
# other through `config.profiles.wakeOnLan.targets`, which this module
# computes when evaluated by reading the `profiles.wakeOnLan` options from
# `self.nixosConfigurations`.  In order to prevent a cyclic module evaluation,
# we must therefore uphold the following invariants:
#
# - The current system being evaluated must be read through `config` (and never
#   through `self`). Reading it through `self` would be the same fixpoint as the
#   system being evaluated (i.e. a cyclic evaluation). It would also ignore any
#   `extendModules` set for that host.
# - Evaluating `profiles.wakeOnLan.targets` for a given host's configuration
#   forces only `profiles.wakeOnLan.target.*` and
#   `profiles.wakeOnLan.relay.enable` options from other hosts' configuration.
#   Those options' definitions must never depend on anything defined in this module's
#   configuration (users, udev rules, secrets). If they do, hosts will start
#   depending on each other cyclically.
# - Other hosts are read from the canonical `nixosConfigurations`, so an
#   `extendModules` variant of one host (an image build, an option test) does
#   not change the configuration seen by other hosts.
{ config, lib, pkgs, self, ... }:
let
  cfg = config.profiles.wakeOnLan;
  hostName = config.networking.hostName;
  # The login user that runs `ssh` on client hosts. See
  # `modules/nixos/default.nix`.
  user = "eliza";

  # Every host's config, with this host read through `config`; see the header.
  allConfigs =
    lib.mapAttrs (_: system: system.config) (removeAttrs self.nixosConfigurations [ hostName ])
    // { ${hostName} = config; };

  relayHosts = lib.attrNames
    (lib.filterAttrs (_: c: c.profiles.wakeOnLan.relay.enable) allConfigs);

  mkTarget = name: target:
    let
      secretName = "wol-${name}";
      rekeyFile = ../../.. + "/secrets/generated/${secretName}.age";
      pubkeyFile = ../../.. + "/secrets/generated/${secretName}.pub";
    in
    {
      inherit (target) mac broadcast;
      # A system configured as both a wake-on-LAN target and as a relay (weird!)
      # should not relay wakeups to itself, since...it'll be asleep...
      relays = lib.remove name relayHosts;
      relayKey = {
        inherit secretName rekeyFile pubkeyFile;
        # This will be `null` if `agenix generate` has not been run to generate
        # the relay key. Evaluating the config for a relay asserts that this is
        # not null, because otherwise, the relay wouldn't actually relay things.
        pubkey =
          if builtins.pathExists pubkeyFile
          then lib.removeSuffix "\n" (builtins.readFile pubkeyFile)
          else null;
        # agenix-rekey generator for the relay private key. The private key is
        # written to the generator's stdout (encrypted by agenix), and the
        # public key is  written next to the `.age` file, so it can be read at
        # eval-time.
        #
        # `agenix generate` runs this as `( script ) || die`, and bash ignores
        # `set -e` on the left of `||`, so every step must check for success.
        generator = { pkgs, lib, file, ... }:
          let
            pubFile = lib.escapeShellArg "${lib.removeSuffix ".age" file}.pub";
          in
          ''
            tmp="$(${pkgs.coreutils}/bin/mktemp -d)" || exit 1
            trap '${pkgs.coreutils}/bin/rm -rf "$tmp"' EXIT
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
              -C ${lib.escapeShellArg secretName} -f "$tmp/key" </dev/null >&2 \
              || exit 1
            ${pkgs.coreutils}/bin/cp "$tmp/key.pub" ${pubFile} || exit 1
            # Untracked files are invisible to flake evaluation, so the relays
            # would not see the pubkey until it is tracked.
            ${pkgs.git}/bin/git add --intent-to-add ${pubFile} || exit 1
            echo "--> wrote "${pubFile} >&2
            ${pkgs.coreutils}/bin/cat "$tmp/key" || exit 1
          '';
      };
    };

  targets = lib.mapAttrs (name: c: mkTarget name c.profiles.wakeOnLan.target)
    (lib.filterAttrs (_: c: c.profiles.wakeOnLan.target.enable) allConfigs);

  # Script to ensure that NICs configured for wake on LAN can actually wake the
  # system. This is run as a oneshot via `SYSTEMD_WANTS` by a udev rule whenever
  # the NIC appears.
  #
  # This script finds the NIC by MAC, then walks from the NIC up to the root of
  # the device tree, enabling wakeup on every device that has the knob (USB hubs
  # and controllers, PCIe bridges), and forbidding D3cold on every PCI device.
  # This is a bit too complex to implement in a udev action, since it must walk
  # up to the root hub. USB wakeup must be enabled on every hub up to and
  # including the root hub.
  #
  # Disabling D3cold is the subtle bit, and is probably only necessary to work
  # around behavior that may be specific to my motherboard (?). In s2idle, the
  # kernel will put PCIe devices (such as the USB root hub) into D3cold, which
  # takes the PCIe link down. In this state, the wake can only be signalled
  # out-of-band on WAKE#. On my SuperMicro H13SRA-TF motherboard, WAKE# is
  # routed to an ACPI GPE (0x18) that the firmware seems to not handle, so the
  # wakeup goes nowhere and does nothing. With the link kept up (D3hot), the USB
  # hub instead delivers an in-band PME message at the root port, which does
  # wake the system. This was discovered experimentally while trying to get WoL
  # to work on hekate. One assumes that it is not necessary on boards not made
  # by StupidMicro, but whatever...
  #
  # The udev rule passes in the NIC's MAC, which is used to find its interface
  # name. This is necessary because the udev rules run before the network
  # interface is renamed to its "predictable" name, so they get the kernel's
  # name rather than the one that eventually ends up in /sys/class/net/. Sigh.
  # Isn't linux cool?
  wakePathScript = pkgs.writeShellApplication {
    name = "wol-wake-path";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      mac=${lib.escapeShellArg cfg.target.mac}

      iface=
      for addr in /sys/class/net/*/address; do
        if [ "$(cat "$addr")" = "$mac" ]; then
          iface="$(basename "$(dirname "$addr")")"
          break
        fi
      done
      if [ -z "$iface" ]; then
        # why would the udev rule have given us a MAC that does not exist?
        # this *probably* only happens if this script is invoked manually...
        echo "<3>no network interface has MAC $mac! this is probably a bug!"
        exit 1
      fi

      failed=0
      dev="$(readlink -f "/sys/class/net/$iface/device")"
      pci_seen=0
      while [ "$dev" != /sys/devices ] && [ "$dev" != / ]; do
        if [ -e "$dev/power/wakeup" ] && ! echo enabled > "$dev/power/wakeup"; then
          echo "<3>$iface: failed to enable wakeup on $dev"
          failed=1
        fi
        if [ -e "$dev/d3cold_allowed" ]; then
          pci_seen=1
          if ! echo 0 > "$dev/d3cold_allowed"; then
            echo "<3>$iface: failed to disable D3cold on $dev"
            failed=1
          fi
        fi
        dev="$(dirname "$dev")"
      done
      if [ "$pci_seen" -eq 0 ]; then
        echo "<4>$iface: no PCI devices above this NIC. seems weird!"
      fi

      if [ "$failed" -ne 0 ]; then
        echo "<3>$iface: wake path only partly configured. wake-on-LAN may not work!"
        exit 1
      fi
      echo "<6>$iface: wake on LAN path configured"
    '';
  };
in
with lib;
{
  options.profiles.wakeOnLan = {
    target = {
      enable = mkEnableOption ''
        waking this host with Wake-on-LAN, including from off the LAN via the
        hosts with `profiles.wakeOnLan.relay.enable`
      '';

      mac = mkOption {
        type = types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
        example = "a0:ce:c8:82:5d:c4";
        description = ''
          MAC address of the NIC that will receive Wake-on-LAN magic packets.
          Note: the MAC address must be written in lower-case.
        '';
      };

      broadcast = mkOption {
        type = types.str;
        example = "10.0.10.255";
        description = ''
          Broadcast address on this host's subnet which relays should use when
          sending magic packets.

          This should be the subnet-directed broadcast address of the wake NIC's
          subnet, rather than 255.255.255.255. This way, if a relay has network
          interfaces on multiple subnets, the magic packet will be always be
          sent on an interface that's on the same subnet as this host.
        '';
      };

      dedicatedNic = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether the Wake-on-LAN NIC (i.e., the interface with the configured
          MAC address) is used only for waking, and should not be used as a
          network interface for other purposes.

          If this is `true`, this module will create a NetworkManager profile
          for the wake-on-LAN NIC that brings its link up, so the PHY stays
          powered and can see magic packets, without configuring any addresses
          on it.

          This is intended for use in situations where the system has multiple
          NICs, and the NIC(s) preferred for most traffic do not support
          Wake-on-LAN.
        '';
      };
    };

    relay.enable = mkEnableOption ''
      relaying Wake-on-LAN magic packets over SSH.

      Systems configured as a relay will have a `wol` SSH user with a forced
      command that sends a magic packet to the MAC of a system considered as a
      wake-on-LAN target. This allows a client not on the same LAN as the target
      to automatically send a magic packet, using a SSH connection to the relay.

      The relay must be on the same LAN as the targets, and should be always on.
      Multiple systems may be used as relays for redundancy.
    '';

    client.enable = mkEnableOption ''
      installing the Wake-on-LAN relay keys for every target in the flake, so
      that `ssh <target>` can wake the target via a relay when off the LAN
    '';

    targets = mkOption {
      type = types.attrsOf types.raw;
      readOnly = true;
      description = ''
        The wake on LAN target configuration for every Wake-on-LAN target in the
        flake, by host name.

        This attrset includes the configured MAC, broadcast address, relays, and
        relay key for each WoL target. It is computed automatically from each
        system config that declares itself as a WoL target.
      '';
    };
  };

  config = mkMerge [
    { profiles.wakeOnLan.targets = targets; }

    (mkIf cfg.target.enable (mkMerge [
      (
        let
          deviceUnitName = "wol-wake-path";
        in
        {
          assertions =
            let
              sameMac = attrNames (filterAttrs
                (name: target: name != hostName && target.mac == cfg.target.mac)
                targets);
            in
            [
              {
                assertion = sameMac == [ ];
                message = ''
                  ${hostName}'s Wake-on-LAN MAC ${cfg.target.mac} is also used by
                  ${concatStringsSep ", " sameMac}. Only one wake-on-LAN target
                  can receive magic packets on a given MAC!
                '';
              }
              {
                assertion = config.networking.networkmanager.enable;
                # TODO(eliza): it would be nice if targets also worked with
                # systemd-networkd (e.g. via a `.link` with `WakeOnLan=`)...
                message = ''
                  ${hostName} enables `profiles.wakeOnLan.target`, which
                  currently requires NetworkManager (to enable Wake-on-LAN on the
                  NIC), but NetworkManager is not enabled.
                '';
              }
            ];

          # Enable magic-packet wake on the target NIC, whichever profile is
          # active on it. This is a per-device *connection default* that applies
          # to every profile on matching devices, unless the profile overrides
          # `ethernet.wake-on-lan`. This way it works regardless of whether the
          # NIC is used for other traffic or not.
          networking.networkmanager.settings."connection-wake-on-lan" = {
            match-device = "mac:${cfg.target.mac}";
            "ethernet.wake-on-lan" = 64;
          };

          # Start the wake-path oneshot unit when the NIC appears.
          services.udev.extraRules = ''
            ACTION=="add", SUBSYSTEM=="net", \
              ATTR{address}=="${cfg.target.mac}", \
              TAG+="systemd", \
              ENV{SYSTEMD_WANTS}+="${deviceUnitName}.service"
          '';
          systemd.services.${deviceUnitName} = {
            description = "Prepare devices to receive wakeups from a Wake-on-LAN NIC";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = getExe wakePathScript;
            };
          };
        }
      )
      (mkIf cfg.target.dedicatedNic {
        networking.networkmanager.ensureProfiles.profiles."wol-${hostName}" = {
          connection = {
            id = "wol-${hostName}";
            type = "ethernet";
            autoconnect = true;
          };
          ethernet.mac-address = cfg.target.mac;
          ipv4.method = "disabled";
          ipv6.method = "disabled";
        };
      })
    ]))

    (mkIf cfg.relay.enable (
      let
        relayTargets = filterAttrs (_: target: elem hostName target.relays) targets;
      in
      {
        assertions = mapAttrsToList
          (name: target: {
            assertion = target.relayKey.pubkey != null;
            message = ''
              ${hostName} is a Wake-on-LAN relay for ${name}, but
              ${toString target.relayKey.pubkeyFile} does not exist. Run
              `agenix generate` and `agenix rekey` to generate it.
            '';
          })
          relayTargets;

        # Create a dedicated user on the relay for the SSH command to run as.
        # Running commands as a normal user would add the relay SSH key to the
        # authorized keys for that user. Even though we configure the
        # authorized_keys entry for the WoL SSH key with `restrict,command=...`
        # so that it cannot run other commands as that user, `pam_rssh` still
        # accepts any of a user's `authorized_keys` as a sudo credential, if the
        # user is a sudoer.
        #
        # By running the command as a dedicated system user, we don't need to
        # worry about accidentally adding a new authorized key that can be used
        # for sudo despite not being hardware-backed.
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
      }
    ))

    (mkIf cfg.client.enable {
      age.secrets = mapAttrs'
        (_: target: nameValuePair target.relayKey.secretName {
          inherit (target.relayKey) rekeyFile;
          generator.script = target.relayKey.generator;
          owner = user;
          mode = "0400";
        })
        targets;
    })
  ];
}
