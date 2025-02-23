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
    services.xserver.displayManager.gdm.autoSuspend = false;
  };
}
