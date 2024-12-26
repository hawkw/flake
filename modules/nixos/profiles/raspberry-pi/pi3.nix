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

    # The last console argument in the list that linux can find at boot will
    # receive kernel logs.
    boot.kernelParams = [
      "console=ttyS0,115200n8" # serial
      "console=ttyS1,115200n8" # other serial
      "console=tty0" # HDMI
    ];
    hardware.deviceTree = {
      enable = true;
      filter = "*rpi-3*.dtb";
    };
  };
}
