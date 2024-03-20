{ config, lib, pkgs, ... }:
let cfg = config.profiles.st-link;
in with lib; {
  options.profiles.st-link = {
    enable = mkEnableOption "udev rules for ST-Link debug probes";
  };

  config =
    let
      # only match USB devices
      subsystem = ''SUBSYSTEM=="usb"'';
      # match devices with the ST vendor ID
      vendor = ''ATTR{idVendor}=="0483"'';
      rulesPath = "/lib/udev/rules.d";
      mkRule = { product, name }:
        (
          ''
            ${subsystem}, ${vendor}, ATTR{idProduct}=="${product}", MODE:="0666", TAG+="uaccess", SYMLINK+="${name}_%n"
          ''
        );
      # ST-Link V2
      v2Rules = pkgs.writeTextFile
        rec {
          name = "49-stlinkv2.rules";
          text =
            (mkRule { product = "3748"; name = "stlinkv2"; });
          destination = "${rulesPath}/${name}";
        };
      # ST-Link V2.1
      v2_1Rules = pkgs.writeTextFile
        rec {
          name = "49-stlinkv2-1.rules";
          text = concatStrings [
            (mkRule { product = "374b"; name = "stlinkv2-1"; })
            (mkRule { product = "3752"; name = "stlinkv2-1"; })
          ];
          destination = "${rulesPath}/${name}";
        };
      # ST-Link V3
      v3Rules = pkgs.writeTextFile rec {
        name = "49-stlinkv3.rules";
        text = concatStrings [

          (mkRule { product = "374d"; name = "stlinkv3loader"; })
          (mkRule { product = "374e"; name = "stlinkv3"; })
          (mkRule { product = "374f"; name = "stlinkv3"; })
          (mkRule { product = "3753"; name = "stlinkv3"; })
          (mkRule { product = "3754"; name = "stlinkv3"; })
        ];
        destination = "${rulesPath}/${name}";
      };
    in
    mkIf cfg.enable
      {
        services.udev.packages = [ v2Rules v2_1Rules v3Rules ];
      };
}
