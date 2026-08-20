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
              hekate = "hekate";
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
                AddKeysToAgent = "yes";
              };
              ${hekate} = hm.dag.entryBefore [ "sysdomain" ] {
                # The attribute name already equals the `Host` pattern, so the
                # `header` is derived as `Host hekate`.
                HostName = "${hekate}.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = "yes";
                PubkeyAuthentication = "unbound";
              };
              sysdomain = hm.dag.entryBefore [ "notSsh" ] {
                header = "Host *.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = "yes";
                PubkeyAuthentication = "unbound";
              };
              "*" = {
                # Settings previously provided by
                # `programs.ssh.enableDefaultConfig`, which has been deprecated.
                ForwardAgent = false;
                # With the 1P agent, adds are refused, so "yes" is inert at
                # best. With the keyring agent, "yes" is what loads a YubiKey
                # key handle (and its gcr-remembered passphrase) on first use.
                AddKeysToAgent = if _1passwordAgent.enable then "no" else "yes";
                Compression = false;
                ServerAliveInterval = 0;
                ServerAliveCountMax = 3;
                HashKnownHosts = false;
                UserKnownHostsFile = "~/.ssh/known_hosts";
                ControlMaster = "no";
                ControlPath = "~/.ssh/master-%r@%n:%p";
                ControlPersist = "no";
              };
            };
        }
        (mkIf _1passwordAgent.enable {
          settings."notSsh" = {
            header = ''Match host * exec "test -z $SSH_CONNECTION"'';
            IdentityAgent = _1passwordAgent.path;
          };
        })
        (mkIf (!_1passwordAgent.enable) {
          # Offer only the keys whose YubiKey is present (see
          # `yubikeyIdentityBlocks` above). We must not add these if the
          # 1Password ssh agent is in use, since setting `IdentitiesOnly` will
          # break it.
          settings = yubikeyIdentityBlocks // {
            "*".IdentitiesOnly = "yes";
          };
        })
      ];
  };
}
