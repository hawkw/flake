{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.raspberry-pi;
in
with lib;
{
  options.profiles.raspberry-pi = {
    pi3.enable = mkEnableOption "Raspberry Pi 3 profile";
  };

  config = mkIf cfg.pi3.enable {
    boot.kernelPackages = pkgs.linuxKernel.packages.linux_rpi3;
    hardware.deviceTree = {
      enable = true;
      filter = "*rpi-3*.dtb";
    };
  };
}
