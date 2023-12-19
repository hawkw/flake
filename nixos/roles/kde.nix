{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    spectacle
    libsForQt5.qtstyleplugin-kvantum
    firefox-devedition-bin
  ];

  services = {
    # Enable the X11 windowing system.
    xserver = {
      enable = true;
      layout = "us";
      # xkbOptions = "eurosign:e";

      # Enable touchpad support.
      # libinput.enable = true;

      # Enable the KDE Desktop Environment.
      displayManager.sddm.enable = true;
      desktopManager.plasma5.enable = true;
    };
    # It's necessary to enable Gnome keyring to make VS Code happy...
    gnome3.gnome-keyring.enable = true;
  };
  security.pam.services = {
    sddm.enableGnomeKeyring = true;
    login.enableGnomeKeyring = true;
  };
  # without dconf you can't change settings in gnome-terminal, so you are
  # stuck with extremely broken font rendering. this is because gnome is
  # extremely well designed.
  programs.dconf.enable = true;
}
