{ config, lib, pkgs, ... }:

let cfg = config.profiles.gnome3;
in {
  options.profiles.gnome3 = with lib; {
    enable = mkEnableOption "gnome3 profile";
  };

  config = lib.mkIf cfg.enable {
    services = {
      xserver = {
        enable = true;
        layout = "us";
        displayManager.gdm.enable = true;
        displayManager.gdm.wayland = true;
        desktopManager.gnome.enable = true;
        displayManager.defaultSession = "gnome";
      };
      dbus.packages = with pkgs; [ dconf ];
      udev.packages = with pkgs; [ gnome3.gnome-settings-daemon ];

      # Enable gnome3 components
      gnome = {
        # Sushi, a quick previewer for Nautilus
        sushi.enable = true;

        # necessary for `programs.firefox.enableGnomeExtensions` i guess?
        gnome-browser-connector.enable = true;
      };
    };

    environment.systemPackages = with pkgs; [ firefox-wayland ];

    programs = {
      # gpaste, a clipboard manager for Gnome
      gpaste.enable = true;

      firefox = {
        package = pkgs.firefox-wayland;
        nativeMessagingHosts.packages = with pkgs; [ gnome-browser-connector ];
      };
    };

    ### gnome-keyring #########################################################
    # enable the Gnome keyring
    services.gnome.gnome-keyring.enable = true;
    # enable gnome keyring unlock on login
    security.pam.services = { login.enableGnomeKeyring = true; };
  };
}
