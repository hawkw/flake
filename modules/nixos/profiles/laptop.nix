{ lib, config, ... }:
let cfg = config.profiles.laptop;
in {
  options.profiles.laptop = with lib; {
    enable = mkEnableOption "laptop profile";
    preferTLP = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to use TLP instead of power profiles daemon.";
    };
    suspendThenHibernate = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description =
          "Whether to setup suspend then hibernate when closing the lid.";
      };
      delayHours = mkOption {
        type = types.int;
        default = 1;
        description =
          "Delay in hours before it should hibernate the laptop after suspending.";
      };
    };
    # rebindKeyboard = {
    #   enable = mkOption {
    #     type = types.bool;
    #     default = true;
    #     description = "Whether to enable the keyboard rebinding daemon.";
    #   };
    #   devices = mkOption {
    #     type = types.listOf types.str;
    #     default = [ "0001:0001" ];
    #     description = ''
    #       List of `<vendor_id>:<product_id>` of the keyboards to apply the rebinding to. By default this only uses `0001:0001` which I've always observed for the built-in keyboard in my laptops.

    #       Discover with `keyd -m`.
    #     '';
    #   };
    # };
  };

  config = lib.mkIf cfg.enable {
    # Enabling the laptop profile automatically enables the
    # desktop profile too.
    profiles.desktop.enable = lib.mkDefault true;

    services = {
      # Enable UPower to watch battery stats.
      upower.enable = true;

      # Enable thermald
      thermald.enable = true;
    };

    # Enable light to control backlight.
    programs.light.enable = true;

    # Setup suspend then hibernate.
    services.logind.lidSwitch =
      if cfg.suspendThenHibernate.enable then
        "suspend-then-hibernate"
      else
        "suspend";
    systemd.sleep.extraConfig =
      lib.optionalString cfg.suspendThenHibernate.enable ''
        HibernateDelaySec=${
          builtins.toString cfg.suspendThenHibernate.delayHours
        }h
      '';
  };
}
