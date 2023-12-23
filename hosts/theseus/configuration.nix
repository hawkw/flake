{ config, pkgs, ... }:

{
  imports = [ # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  networking.hostName = "theseus"; # Define your hostname.

  profiles = {
    docs.enable = true;
    gnome3.enable = true;
    observability.enable = true;
  };

  #### System configuration ####

  # Bootloader.
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # use the latest stable Linux kernel
    kernelPackages = pkgs.linuxPackages_latest;

    initrd.luks.devices."luks-c8e922ff-11e1-473c-a52e-c2b86a042e44".device =
      "/dev/disk/by-uuid/c8e922ff-11e1-473c-a52e-c2b86a042e44";
  };

  services = {
    # use `fwupdmgr` for updating Framework firmware
    fwupd.enable = true;

    # For fingerprint support
    fprintd.enable = true;
  };

  # As of firmware v03.03, a bug in the EC causes the system to wake if AC is
  # connected despite the lid being closed. The following works around this,
  # with the trade-off that keyboard presses also no longer wake the system.
  # see https://github.com/NixOS/nixos-hardware/tree/7763c6fd1f299cb9361ff2abf755ed9619ef01d6/framework/13-inch/7040-amd#suspendwake-workaround
  # hardware.framework.amd-7040.preventWakeOnAC = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
