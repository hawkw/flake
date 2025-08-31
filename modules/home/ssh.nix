{ config, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };
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
          # `enableDefaultConfig` is deprecated; these settings are now in
          # `matchBlocks."*".
          enableDefaultConfig = false;
          matchBlocks =
            let
              hekate = "hekate";
              noctis = "noctis";
              noctis-tailscale = "${noctis}-tailscale";
              sys-domain = "sys.home.elizas.website";
            in
            {
              # "${noctis}-local" = hm.dag.entryBefore [ noctis-tailscale ] {
              #   match = ''host ${noctis} exec "ping -c1 -W1 -q ${noctis}.local"'';
              #   hostname = "noctis.local";
              # };
              ${noctis-tailscale} = hm.dag.entryBefore [ "notSsh" ] {
                host = noctis;
                hostname = noctis;
              };
              ${hekate} = hm.dag.entryBefore [ "notSsh" ] {
                host = hekate;
                hostname = "${hekate}.${sys-domain}";
              };
              "*" = {
                # Settings previously provided by
                # `programs.ssh.enableDefaultConfig`, which has been deprecated.
                # Note that this does *not* set `ForwardAgent no` or
                # `AddKeysToAgent no`, because I don't want to disable those.
                compression = false;
                serverAliveInterval = 0;
                serverAliveCountMax = 3;
                hashKnownHosts = false;
                userKnownHostsFile = "~/.ssh/known_hosts";
                controlMaster = "no";
                controlPath = "~/.ssh/master-%r@%n:%p";
                controlPersist = "no";
              };
            };
        }
        (mkIf _1passwordAgent.enable {
          matchBlocks."*" = {
            forwardAgent = true;
            addKeysToAgent = "yes";
          };
          matchBlocks."notSsh" = {
            match = ''host * exec "test -z $SSH_CONNECTION"'';
            extraOptions = {
              IdentityAgent = _1passwordAgent.path;
            };
          };
        })
      ];
  };
}
