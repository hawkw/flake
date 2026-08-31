{ config, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };

  # SSH identities for provisioned YubiKeys (see lib/yubikeys.nix). The key
  # handles live in ~/.ssh on machines they've been copied to.
  yubikeys = import ../../lib/yubikeys.nix { inherit lib; };
  # Generate SSH config blocks setting `IdentityFile` for yubikey-backed SSH
  # keys.
  #
  # These have a `Match exec` clause that checks for the presence of the
  # corresponding Yubikey (via the symlinks we set up in
  # `nixos/profiles/yubikey.nix`). This way, we only offer the key from the
  # Yubikey that's actually present, which stops ssh from printing a bunch of
  # junk complaining that it tried to offer *all* the yubikey-backed SK keys and
  # two of them didn't work. This is not strictly necessary (ssh still
  # ultimately *works* if it offers the not-present keys) but i didn't love that
  # it printed a bunch of complaints.
  yubikeyIdentityBlocks = lib.mapAttrs'
    (serial: key:
      lib.nameValuePair "yubikey-present-${serial}" {
        header = ''Match exec "test -e /dev/yubikey/${serial}"'';
        IdentityFile = "~/.ssh/${key.privkeyFilename}";
        # Restrict ssh to only offer the identity file for the present Yubikey.
        # This prevents SSH from offering all SK keys (including those for the
        # not-physically-connected Yubikeys), which results in printing errors
        # that it can't use those keys.
        #
        # IdentitiesOnly is only set when we *did* find a physically present
        # yubikey. Otherwise, it would also prevent offering forwarded keys when
        # SSHed into a remote system, where /dev/yubikey/$SERIAL doesn't exist.
        IdentitiesOnly = "yes";
      })
    yubikeys.ssh.bySerial;
in
with lib;
{
  options.programs._1password-gui.enableSshAgent =
    mkEnableOption "Enable 1Password SSH Agent";

  config = {
    home.packages = with pkgs; [ ssh-tools ];
    programs.ssh =
      mkMerge [
        {
          enable = true;
          # `enableDefaultConfig` is deprecated; the equivalent defaults are
          # set manually in `settings."*"` below.
          enableDefaultConfig = false;
          settings =
            let
              homeHosts = [ "hekate" "noctis" "tranquility" "tereshkova" ];
              noctis = "noctis";
              noctis-tailscale = "${noctis}-tailscale";
              sysdomain = "sys.home.elizas.website";
            in
            {
              # "${noctis}-local" = hm.dag.entryBefore [ noctis-tailscale ] {
              #   header = ''Match host ${noctis} exec "ping -c1 -W1 -q ${noctis}.local"'';
              #   HostName = "noctis.local";
              # };
              ${noctis-tailscale} = hm.dag.entryBefore [ "notSsh" ] {
                header = "Host ${noctis}";
                HostName = noctis;
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

              # The attribute name already equals the `Host` pattern, so the
              # `header` is derived as `Host hekate`.
              homeAliases = hm.dag.entryBefore [ "sysdomain" ] {
                header = "Host ${concatStringsSep " " homeHosts}";
                HostName = "%h.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

              sysdomain = hm.dag.entryBefore [ "notSsh" ] {
                header = "Host *.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

              "*" = {
                # Settings previously provided by
                # `programs.ssh.enableDefaultConfig`, which has been deprecated.
                ForwardAgent = false;
                # With the 1P agent, adds are refused, so "yes" is inert at
                # best. With the keyring agent, "yes" is necessary to load a
                # YubiKey key handle on first use.
                AddKeysToAgent = if _1passwordAgent.enable then "no" else "yes";
                Compression = false;
                ServerAliveInterval = 0;
                ServerAliveCountMax = 3;
                HashKnownHosts = false;
                UserKnownHostsFile = "~/.ssh/known_hosts";
                ControlMaster = false;
                ControlPath = "~/.ssh/master-%r@%n:%p";
                ControlPersist = false;
              };
            };
        }
        (mkIf _1passwordAgent.enable {
          settings."notSsh" = {
            header = ''Match host * exec "test -z $SSH_CONNECTION"'';
            IdentityAgent = _1passwordAgent.path;
          };
        })

        # If 1Password agent is not in use, add the Yubikey identity blocks
        # generated above. Since these set `IdentitiesOnly`, they would break
        # the 1Password agent and should only be added if it's not in use.
        (mkIf (!_1passwordAgent.enable) {
          settings = yubikeyIdentityBlocks;
        })
      ];
  };
}
