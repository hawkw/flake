{ config, pkgs, lib, ... }:

let
  cfg = config.profiles.desktop.gnome3;

  # configure installed Gnome 3 extensions
  # note: these have to be *enabled* manually in the gnome extensions UI...
  gnome_extensions = with pkgs.gnomeExtensions; [
    # a nicer application menu for gnome
    arc-menu
    # displays system status in the gnome-shell status bar
    # system-monitor
    # displays system temperatures, fan RPMs, and voltages
    # freon
    # allows selecting the sound output device in the sound menu
    sound-output-device-chooser
    # zfs-status-monitor
    # POP!_OS shell tiling extensions for Gnome 3
    pop-shell
    # dash-to-dock-for-cosmic
    tailscale-status
  ];
  # configure Gnome themes
  themes = with pkgs; [
    ant-theme
    ant-nebula-theme
    dracula-theme
    arc-theme
    arc-icon-theme
    equilux-theme
    pop-gtk-theme
    pop-icon-theme
    qogir-theme
    yaru-theme
    matcha-gtk-theme
  ];
in
with lib; {

  options.profiles.desktop.gnome3 = {
    enable = mkEnableOption "gnome3 profile";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs;
      [
        # useful for testing webcams, etc
        cheese
        # A tool to customize advanced GNOME 3 options
        gnome-tweaks
        # A nice way to view information about use of system resources, like memory
        # and disk space
        gnome-usage
        ocs-url
      ] ++ gnome_extensions ++ themes;

    programs.firefox = { package = pkgs.firefox-wayland; };

    #### gnome-keyring ########################################################
    services.gnome-keyring = {
      enable = true;
      components = [ "pkcs11" "secrets" "ssh" ];
    };
  };
}
