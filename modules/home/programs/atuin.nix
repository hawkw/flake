{ config, pkgs, lib, ... }:
let
  cfg = config.programs.atuin;
in
with lib;
{
  options.programs.atuin = {
    enableDaemon = mkEnableOption "the Atuin sync daemon";
  };

  config = mkIf cfg.enable (mkMerge [
    {
      programs.atuin.settings = {
        style = "auto";
        # style = "compact";
        # inline_height = 20;
        dialect = "us";
        auto_sync = true;

      };
    }
    (mkIf cfg.enableDaemon (
      let
        name = "atuind";
        socket = "atuin.socket";
      in
      {
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

        # Unix socket activation for atuin shell history daemon.
        # See: https://github.com/Nemo157/dotfiles/commit/967719ddc17c1d0060240106df1ca14c058936d2 
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
          socket_path = "/run/user/1000/${socket}";
          systemd_socket = true;
          sync_frequency = "30";
        };
      }
    )
    )
  ]);

}
