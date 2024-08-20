{ config, pkgs, lib, ... }:
let
  cfg = config.services.atuin-daemon;
  name = "atuind";
  socket = "atuin.socket";
in
with lib; {
  options.services.atuin-daemon.enable = mkEnableOption "atuin-daemon";

  config = mkIf cfg.enable {
    # Running the daemon should fix ZFS-related issues. 
    # See: https://github.com/atuinsh/atuin/issues/952
    #
    # This systemd unit config is based on the one from this thread:
    # https://forum.atuin.sh/t/getting-the-daemon-working-on-nixos/334
    systemd.user.services.${name} = {
      Unit = {
        Description = "Atuin daemon";
        Requires = [ "${name}.socket" ];
      };
      Service = {
        Environment = [ "ATUIN_LOG=info" ];
        ExecStart = "${getExe pkgs.atuin} daemon";

        Restart = "on-failure";
        RestartSteps = 5;
        RestartMaxDelaySec = 10;
      };
      Install = {
        Also = [ "${name}.socket" ];
        WantedBy = [ "default.target" ];
      };
    };

    systemd.user.sockets.${name} = {
      Unit = {
        Description = "Unix socket activation for atuin shell history daemon";
      };

      Socket = {
        ListenStream = "%t/${socket}";
        SocketMode = "0600";
        RemoveOnStop = true;
      };

      Install = {
        WantedBy = [ "sockets.target" ];
      };
    };

    programs.atuin.settings.daemon = {
      enabled = true;
      socket_path = "/run/user/1000/${socket}";
      systemd_socket = true;
    };
  };
}
