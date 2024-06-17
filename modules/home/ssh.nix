{ config, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };
  authSockPath = "${config.home.homeDirectory}/.ssh/ssh_auth_sock";
in
with lib;
{
  options.programs._1password-gui.enableSshAgent =
    mkEnableOption "Enable 1Password SSH Agent";

  config = mkIf _1passwordAgent.enable {
    # home.file.".ssh/rc".source = pkgs.writeScript "ssh-agent-rc" ''
    #   # create/update symlink only if interactive ssh login AND ~/.ssh/ssh_auth_sock doesn't exist AND $SSH_AUTH_SOCK does exist
    #   if [[ -n "$SSH_TTY" && ! -S ${authSockPath} && -S "$SSH_AUTH_SOCK" ]]; then
    #       ln -sf $SSH_AUTH_SOCK ${authSockPath}
    #   fi
    # '';
    programs.ssh = {
      enable = true;
      forwardAgent = _1passwordAgent.enable;
      addKeysToAgent = "yes";
      matchBlocks = {
        # hasAuthSock = {
        #   match = ''host * exec "test -S ${authSockPath}"'';
        #   extraOptions = {
        #     IdentityAgent = authSockPath;
        #   };
        # };
        # noAuthSock = hm.dag.entryAfter [ "hasAuthSock" ] {

        authSock = {
          match = "host *";
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
