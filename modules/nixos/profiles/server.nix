# Configuration for server systems
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.server;
in
{
  options.profiles.server = {
    enable = mkEnableOption "server defaults profile";

    idleSuspend = {
      enable = mkEnableOption ''
        suspending when the system is idle, using logind's `IdleAction`.

        logind considers the system idle when no idle inhibitor is held and
        every session that counts is idle. SSH sessions with a pty count as
        idle once their tty has seen no input for `timeout`; SSH sessions
        without a pty (`ssh host cmd`, scp, deploy-rs, remote builds) never
        count as idle, so they keep the system awake while connected. Long jobs
        in an interactive shell should be wrapped in
        `systemd-inhibit --what=idle`, or they will be suspended mid-run.

        Hibernation stays disabled'';

      timeout = mkOption {
        type = types.str;
        default = "30min";
        description = "How long the system must be idle before suspending, as a systemd time span.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in
      # GUI! If no user is logged in, the machine will power down after 20
      # minutes. This stays off even with `idleSuspend`, because GDM's timer
      # only sees local input, not SSH sessions.
      services.displayManager.gdm.autoSuspend = false;
      # Hibernating with a ZFS root risks pool corruption.
      systemd.targets = {
        hibernate.enable = false;
        hybrid-sleep.enable = false;
      };
    }
    (mkIf (!cfg.idleSuspend.enable) {
      systemd.targets = {
        sleep.enable = false;
        suspend.enable = false;
      };
    })
    (mkIf cfg.idleSuspend.enable {
      services.logind.settings.Login = {
        IdleAction = "suspend";
        IdleActionSec = cfg.idleSuspend.timeout;
      };
    })
  ]);
}
