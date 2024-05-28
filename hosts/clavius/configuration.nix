{ pkgs, config, lib, ... }:
{
  system.stateVersion = "23.11";
  services.openssh.enable = true;
  raspberry-pi.hardware.platform.type = "rpi3";
}
