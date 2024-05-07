{ config, lib, pkgs, ... }:

let cfg = config.profiles.desktop;
in {
  options.profiles.desktop.kde = with lib; {
    enable = mkEnableOption "KDE profile";
  };

  config = lib.mkIf cfg.kde.enable {
    profiles.desktop.enable = lib.mkDefault true;

    environment.systemPackages = with pkgs; [
      spectacle
      libsForQt5.qtstyleplugin-kvantum
      firefox-devedition-bin
    ];

    services = {
      xserver = {
        # xkbOptions = "eurosign:e";

        # Enable touchpad support.
        # libinput.enable = true;

        # Enable the KDE Desktop Environment.
        displayManager.sddm.enable = true;
        desktopManager.plasma5.enable = true;
      };
      # It's necessary to enable Gnome keyring to make VS Code happy...
      gnome.gnome-keyring.enable = true;
    };
    security.pam.services = {
      sddm.enableGnomeKeyring = true;
      login.enableGnomeKeyring = true;
    };
    # without dconf you can't change settings in gnome-terminal, so you are
    # stuck with extremely broken font rendering. this is because gnome is
    # extremely well designed.
    programs.dconf.enable = true;
  };
}
