{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.raspberry-pi;
in
with lib;
{
  options.profiles.raspberry-pi = {
    pi4.enable = mkEnableOption "Raspberry Pi 4 profile";
  };

  config = mkIf cfg.pi4.enable {
    boot.kernelPackages = pkgs.linuxKernel.packages.linux_rpi4;
    warnings = "Pi 4 profile doesn't currently do much of anything!";
  };
}
