# The registry of hosts that can be woken with Wake-on-LAN, and how to wake
# them from off the LAN.
#
# A magic packet is an Ethernet broadcast, so it can't cross the WireGuard
# tunnel into the home network, and the UniFi gateway has no persistent way to
# turn a routed packet into one. Instead, each target names a *relay*: an
# always-on host in the same broadcast domain. Clients SSH to the relay with a
# dedicated key whose `authorized_keys` entry is restricted to running
# `wakeonlan` for that one target, and nothing else.
#
# The moving parts, and who owns them:
#
# - The target host arms WoL on its NIC (see `hosts/<target>/configuration.nix`).
# - The relay (`modules/nixos/profiles/wol.nix`) authorizes each target's relay
#   key for the `wol` user, forced to `wakeonlan <mac>`. A host is a relay
#   exactly when some target here names it as `relay`.
# - Clients (`profiles.wol.client.enable`) receive each target's relay private
#   key as an agenix secret.
# - The home-manager SSH config (`modules/home/ssh.nix`) sets a `ProxyCommand`
#   for each target that wakes it (locally and via the relay) on connect.
{ lib }:
let
  targets = {
    hekate = {
      mac = "7c:c2:55:6a:76:08";
      relay = "tereshkova";
      # The relay sends to the subnet-directed broadcast address rather than
      # 255.255.255.255, so that the packet leaves through the interface on
      # this subnet even if the relay has more than one. This assumes the
      # 10.0.10.0/24 VLAN.
      broadcast = "10.0.10.255";
    };
  };

  mkTarget = name: target:
    let
      secretName = "wol-${name}";
      rekeyFile = ../secrets/generated + "/${secretName}.age";
      pubkeyFile = ../secrets/generated + "/${secretName}.pub";
    in
    target // {
      relayKey = {
        inherit secretName rekeyFile pubkeyFile;
        # `null` until `agenix generate` has run. The relay asserts on this,
        # rather than silently authorizing nothing.
        pubkey =
          if builtins.pathExists pubkeyFile
          then lib.removeSuffix "\n" (builtins.readFile pubkeyFile)
          else null;
        # agenix-rekey generator for the relay private key. The private key is
        # the generator's stdout (encrypted by agenix); the public key is
        # written next to the `.age` file, so it can be read at eval time.
        #
        # This must only use the `pkgs` passed to the generator, not a host's
        # `pkgs`: `agenix generate` requires every host declaring this secret
        # to produce an identical script, and hosts differ in architecture.
        generator = { pkgs, lib, file, ... }:
          let
            pubFile = lib.escapeShellArg "${lib.removeSuffix ".age" file}.pub";
          in
          # `agenix generate` runs this as `( script ) || die`, and bash ignores
            # `set -e` on the left of `||`, so every step must check itself.
          ''
            tmp="$(${pkgs.coreutils}/bin/mktemp -d)" || exit 1
            trap '${pkgs.coreutils}/bin/rm -rf "$tmp"' EXIT
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
              -C ${lib.escapeShellArg secretName} -f "$tmp/key" </dev/null >&2 \
              || exit 1
            ${pkgs.coreutils}/bin/cp "$tmp/key.pub" ${pubFile} || exit 1
            # Untracked files are invisible to flake evaluation, so the relay
            # would not see the pubkey until it is tracked.
            ${pkgs.git}/bin/git add --intent-to-add ${pubFile} || exit 1
            echo "--> wrote "${pubFile} >&2
            ${pkgs.coreutils}/bin/cat "$tmp/key" || exit 1
          '';
      };
    };
in
{
  targets = lib.mapAttrs mkTarget targets;
}
