{ config, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };

  # SSH identities for provisioned YubiKeys (see lib/yubikeys.nix). The key
  # handles live in ~/.ssh on machines they've been copied to. Because ssh
  # silently skips IdentityFiles that don't exist, it's fine to just include
  # each YubiKey's key in IdentityFiles all the time, and SSH will select
  # whichever one is physically present.
  #
  # These are only wired up when the 1Password SSH agent is disabled, because the 1P
  # agent can neither hold nor add sk keys, so with `IdentityAgent` pointing
  # at it the handles would degrade to passphrase-per-connection file reads.
  # The `enableSshAgent` option is the per-host transition knob --- flip it
  # off to switch a host to YubiKey-backed SSH auth (via the gnome-keyring
  # agent). Once I've validated the YubiKey scheme end-to-end, the 1Password
  # agent wiring can be deleted entirely.
  yubikeys = import ../../lib/yubikeys.nix { inherit lib; };
  yubikeyIdentityFiles = map (f: "~/.ssh/" + f) yubikeys.ssh.privkeyFilenames;
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
                # Generating the SSH config will omit values that are empty
                # lists, so this disappears entirely while no YubiKeys are
                # enrolled.
                IdentityFile = yubikeyIdentityFiles;
              };
            };
        }
        (mkIf _1passwordAgent.enable {
          settings."notSsh" = {
            header = ''Match host * exec "test -z $SSH_CONNECTION"'';
            IdentityAgent = _1passwordAgent.path;
          };
        })
      ];
  };
}
