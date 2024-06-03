{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.raspberry-pi;
in
with lib;
{
  imports = [
    ./pi3.nix
    ./pi4.nix
    ./pi5.nix
  ];

  options.profiles.raspberry-pi = {
    i2c.enable = mkEnableOption "Raspberry Pi I2C devices";
  };

  config = mkIf (cfg.pi3.enable || cfg.pi4.enable || cfg.pi5.enable) (mkMerge [
    {
      security.sudo-rs.enable = mkForce false;
      security.sudo.enable = true;

      boot = {
        initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
        loader = {
          grub.enable = false;
          generic-extlinux-compatible.enable = true;
        };
        tmp.cleanOnBoot = true;
      };

      # don't install documentation, in order to save space on the SD card
      documentation.nixos.enable = false;
      # enable automatic nix gc
      nix.gc = {
        automatic = true;
        options = "--delete-older-than 30d";
      };

    }
    (mkIf cfg.i2c.enable {
      hardware.i2c.enable = true;
      # also, it's nice to have the i2c-tools package installed for debugging...
      environment.systemPackages = with pkgs; [ i2c-tools ];
    })
  ]);
}
