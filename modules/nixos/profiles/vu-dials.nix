{ config, lib, ... }:
let cfg = config.profiles.vu-dials;
in with lib; {
  options.profiles.vu-dials = {
    enable = mkEnableOption "my Streacom VU-1 dials config";
  };

  config = mkIf cfg.enable {

    # VU1 Dials server
    services.vu-dials.server = {
      enable = true;
      logLevel = "info";
    };

    # vupdated
    services.vu-dials.vupdated = {
      enable = true;
      enableHotplug = lib.mkDefault true;
      logFilter = "info,vupdated=debug";
      dials =
        let
          backlight =
            {
              mode = {
                static = {
                  red = 100;
                  green = 65;
                  blue = 0;
                };
              };
            };
          update-interval = "1s";
        in
        {
          "CPU Load" = {
            index = 0;
            metric = "cpu-load";
            inherit update-interval backlight;
          };
          "CPU Temp" = {
            index = 1;
            metric = "cpu-temp";
            inherit update-interval backlight;
          };
          "Memory Usage" = {
            index = 2;
            metric = "mem";
            inherit update-interval backlight;
          };
          "Swap Usage" = {
            index = 3;
            metric = "swap";
            inherit update-interval backlight;
          };
        };
    };

    # dialctl
    programs.vu-dials.dialctl.enable = true;
  };
}
