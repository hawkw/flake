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
            };
        }
        (mkIf _1passwordAgent.enable {
          forwardAgent = _1passwordAgent.enable;
          addKeysToAgent = "yes";
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
