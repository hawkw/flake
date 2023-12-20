{ config, lib, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };
in {
  options.programs._1password-gui.enableSshAgent =
    lib.mkEnableOption "Enable 1Password SSH Agent";

  config = {
    programs.ssh = {
      enable = true;
      forwardAgent = _1passwordAgent.enable;
      extraConfig = lib.optionalString _1passwordAgent.enable
        "IdentityAgent ${_1passwordAgent.path}";
    };
  };
}
