{ config, lib, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };
in
{
  options.programs._1password-gui.enableSshAgent =
    lib.mkEnableOption "Enable 1Password SSH Agent";

  config = {
    programs.ssh = {
      enable = true;
      forwardAgent = _1passwordAgent.enable;
      addKeysToAgent = "yes";
      extraConfig = lib.optionalString _1passwordAgent.enable
        ''
          # override IdentityAgent parameter for all hosts if forwarded SSH agent is present
          Match host * exec "test -S ~/.ssh/ssh_auth_sock"
              IdentityAgent ~/.ssh/ssh_auth_sock

          # use 1password ssh agent as default
          Match host *
              IdentityAgent ${_1passwordAgent.path}
        '';
    };
  };
}
