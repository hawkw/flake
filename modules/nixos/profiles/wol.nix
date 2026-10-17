# Wake-on-LAN relaying. See `lib/wol.nix` for the overall design.
#
# This module has two independent roles:
#
# - **Relay**: enabled automatically on any host that `lib/wol.nix` names as a
#   target's `relay`. Authorizes each such target's relay key for the `wol`
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
    (_: target: target.relay == config.networking.hostName)
    wol.targets;
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
