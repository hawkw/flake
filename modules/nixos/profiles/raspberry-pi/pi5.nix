{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.raspberry-pi;
in
with lib;
{
  options.profiles.raspberry-pi = {
    pi5.enable = mkEnableOption "Raspberry Pi 5 profile";
  };

  config = mkIf cfg.pi4.enable {
    boot.kernelPackages = pkgs.linuxKernel.packages.linux_rpi5;
    warnings = "Pi 5 profile doesn't currently do much of anything!";
  };
}
