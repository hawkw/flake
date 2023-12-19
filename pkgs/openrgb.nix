{ config, pkgs, lib, ... }:

let
  enableService = config.services.openrgb.enable;
  enableDesktop = config.programs.openrgb.enable;
in with lib; {
  options = {
    services.openrgb.enable = mkEnableOption "OpenRGB background service";
    programs.openrgb.enable = mkEnableOption "OpenRGB";
  };
  config = mkMerge [
    {
      environment.systemPackages = with pkgs; [ openrgb i2c-tools ];
      boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];
      services.udev.packages = with pkgs; [ openrgb ];
    }

    # if the systemd service is enabled
    (mkIf enableService {
      systemd.user.services.openrgb = {
        wantedBy = [ "multi-user.target" ];
        description = "OpenRGB RGB controller";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.openrgb}/bin/openrgb --server";
          Group = "i2c";
        };
      };
    })
    # if the desktop entry is enabled
    (mkIf enableDesktop {
      environment.systemPackages = let
        desktopItem = pkgs.makeDesktopItem {
          type = "Application";
          # encoding = "UTF-8";
          name = "OpenRGB";
          desktopName = "OpenRGB";
          comment = "Control RGB lighting";
          icon = "OpenRGB";
          exec = "${pkgs.openrgb}/bin/openrgb";
          terminal = false;
          categories = [ "Utility" ];
        };
      in [ desktopItem ];
    })
  ];
}
