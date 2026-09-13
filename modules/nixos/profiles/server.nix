# Configuration for server systems
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.server;
in
{
  options.profiles.server.enable = mkEnableOption "server defaults profile";

  config = mkIf cfg.enable {
    # Disable auto-suspend if gdm is installed.
    services.displayManager.gdm.autoSuspend = false;
    # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
    # If no user is logged in, the machine will power down after 20 minutes.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };
  };
}
