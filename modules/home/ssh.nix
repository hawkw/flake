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
          # Use 1password ssh agent if not on a SSH connection.
          Match host * exec "test -Z $SSH_TTY"
            IdentityAgent ${_1passwordAgent.path}
        '';
    };
  };
}
