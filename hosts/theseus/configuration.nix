{ config, pkgs, ... }:

{

  profiles = {
    docs.enable = true;
    gnome3.enable = true;
    observability.enable = true;
  };

  #### System configuration ####
  networking = {
    # machine's hostname
    hostName = "theseus";
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

}
