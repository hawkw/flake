{ config, lib, ... }:
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

  config = mkIf _1passwordAgent.enable {
    programs.ssh = {
      enable = true;
      forwardAgent = _1passwordAgent.enable;
      addKeysToAgent = "yes";
      matchBlocks = {
        "notSsh" = {
          # match = ''host * exec "test -z $SSH_CONNECTION"'';
          extraOptions = {
            IdentityAgent = _1passwordAgent.path;
          };
        };
        "noctis" = {
          host = "noctis";
        };
      };
    };
  };
}
