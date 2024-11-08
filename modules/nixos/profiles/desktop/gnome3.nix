{ config, lib, pkgs, ... }:

let cfg = config.profiles.desktop;
in with lib; {
  options.profiles.desktop.gnome3 = {
    enable = mkEnableOption "gnome3 profile";
  };

  config = mkIf cfg.gnome3.enable {
    profiles.desktop.enable = mkDefault true;

    services = {
      displayManager.defaultSession = "gnome";
      xserver = {
        # Enable the GNOME Desktop Environment.
        desktopManager.gnome.enable = true;
        displayManager = {
          gdm = {
            enable = true;
            wayland = true;
          };
        };
      };

      dbus.packages = with pkgs; [ dconf ];
      udev.packages = with pkgs; [ gnome-settings-daemon ];

      # Enable gnome3 components
      gnome = {
        # Sushi, a quick previewer for Nautilus
        sushi.enable = true;

        # necessary for `programs.firefox.enableGnomeExtensions` i guess?
        gnome-browser-connector.enable = true;
      };
    };

    programs = {
      # gpaste, a clipboard manager for Gnome
      gpaste.enable = true;

      firefox = {
        package = pkgs.firefox-wayland;
        # nativeMessagingHosts.packages = with pkgs; [ gnome-browser-connector ];
      };
    };

    ### gnome-keyring #########################################################
    # enable the Gnome keyring
    services.gnome.gnome-keyring.enable = mkDefault true;
    # enable gnome keyring unlock on login
    security.pam.services = {
      login.enableGnomeKeyring = mkDefault true;
    };
  };
}
