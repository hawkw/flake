{ config, pkgs, ... }:

{
  # NixOS wants to enable GRUB by default
  boot.loader.grub.enable = false;
  # Enables the generation of /boot/extlinux/extlinux.conf
  boot.loader.generic-extlinux-compatible.enable = true;

  hardware.enableRedistributableFirmware = true;
  #   networking.wireless.enable = true;
  #   # !!! This is only for ARMv6 / ARMv7. Don't enable this on AArch64, cache.nixos.org works there.
  #   nix.binaryCaches = lib.mkForce [ "https://cache.armv7l.xyz" ];
  #   nix.binaryCachePublicKeys =
  #     [ "cache.armv7l.xyz-1:kBY/eGnBAYiqYfg0fy0inWhshUo+pGFM3Pj7kIkmlBk=" ];

  #   # nixos-generate-config should normally set up file systems correctly
  #   imports = [ ./hardware-configuration.nix ];
  #   # If not, you can set them up manually as shown below
  #   /*
  #   fileSystems = {
  #     # Prior to 19.09, the boot partition was hosted on the smaller first partition
  #     # Starting with 19.09, the /boot folder is on the main bigger partition.
  #     # The following is to be used only with older images. Note such old images should not be considered supported anymore whatsoever, but if you installed back then, this might be needed
  #     /*
  #     "/boot" = {
  #       device = "/dev/disk/by-label/NIXOS_BOOT";
  #       fsType = "vfat";
  #     };
  #     */
  #     "/" = {
  #       device = "/dev/disk/by-label/NIXOS_SD";
  #       fsType = "ext4";
  #     };
  #   };
  #   */

  # !!! Adding a swap file is optional, but recommended if you use RAM-intensive applications that might OOM otherwise. 
  # Size is in MiB, set to whatever you want (though note a larger value will use more disk space).
  # swapDevices = [ { device = "/swapfile"; size = 1024; } ];

  profiles = {
    observability = {
      enable = true;
      prometheus.enableMdns = true;
    };
  };

  services.nginx.enable = true;
}
