{ config, lib, ... }:
{
  system.stateVersion = "23.11";
  raspberry-pi.hardware.platform.type = "rpi3";

  services = {
    eclssd.enable = true;
    openssh.enable = true;
  };

  security.sudo-rs.enable = lib.mkForce false;

  profiles = {
    observability.enable = true;
  };

  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │ ${config.networking.hostName}: environmental monitoring and control
    └┴────────────────┘
  '';
}
