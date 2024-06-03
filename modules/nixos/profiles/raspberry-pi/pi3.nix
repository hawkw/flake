{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.raspberry-pi;
in
with lib;
{
  options.profiles.raspberry-pi = {
    pi3.enable = mkEnableOption "Raspberry Pi 3 profile";
  };

  config = mkIf cfg.pi3.enable (mkMerge [
    {
      boot.kernelPackages = pkgs.linuxKernel.packages.linux_rpi3;
      hardware.deviceTree = {
        enable = true;
        filter = "*rpi-3*.dtb";
      };
    }
    (mkIf cfg.i2c.enable {
      # enable I2C-1 on the Raspberry Pi 3
      #
      # TODO(eliza): `hardware.raspberry-pi."4".i2c1.enable` in
      # `nixos-hardware` will add an *almost identical* devicetree overlay,
      # except it has `compatible = "brcm,bcm2711"` in it, making it only work
      # on the Pi 4, and not the Pi 3. see:
      # https://github.com/NixOS/nixos-hardware/blob/7b49d3967613d9aacac5b340ef158d493906ba79/raspberry-pi/4/i2c.nix
      #
      # it would be nice to upstream this change to nixos-hardware eventually
      # to add i2c support for the Pi 3.
      hardware.deviceTree.overlays = [
        {
          name = "i2c1-okay-overlay";
          dtsText = ''
            /dts-v1/;
            /plugin/;
            / {
              compatible = "raspberrypi";
              fragment@0 {
                target = <&i2c1>;
                __overlay__ {
                  status = "okay";
                };
              };
            };
          '';
        }
      ];
    })
  ]);
}
