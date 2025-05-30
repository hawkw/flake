# Profile for desktop machines (i.e. not servers).
{ config, lib, pkgs, ... }:
let cfg = config.profiles.desktop;
in {

  imports = [ ./gnome3.nix ./kde.nix ];

  options.profiles.desktop = with lib; {
    enable = mkEnableOption "Profile for desktop machines (i.e. not servers)";
  };

  config = lib.mkIf cfg.enable {
    # Use latest kernel by default.
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    ### pipewire ###
    # Use PipeWire as the system audio/video bus
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };
      jack.enable = true;
      pulse.enable = true;
      socketActivation = true;
    };

    ### services ###

    services = {
      # Enable the X11 windowing system.
      xserver = with lib; {
        enable = mkDefault true;

        # Configure keymap in X11
        xkb = {
          layout = mkDefault "us";
          variant = mkDefault "";
        };
      };

      # Enable CUPS to print documents.
      printing.enable = lib.mkDefault true;

    };

    ### hardware ###
    hardware = {
      bluetooth.enable = lib.mkDefault true;
      ergodox.enable = lib.mkDefault true;
    };

    ### programs ###
    programs = {
      # Enable 1password and 1password-gui
      _1password.enable = true;
      _1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "eliza" ];
      };

      firefox.enable = true;
    };

  };
}
