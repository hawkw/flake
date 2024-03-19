{ config, lib, ... }:
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
      mkRule = { product, name }:
        (
          ''
            ${subsystem}, ${vendor}, ATTR{idProduct}=="${product}", MODE="600", TAG+="uaccess", SYMLINK+="${name}_%n"
          ''
        );

    in
    mkIf cfg.enable
      {
        services.udev.extraRules = concatStrings [

          # ST-Link V2
          (mkRule { product = "3748"; name = "stlinkv2"; })
          # ST-Link V2.1
          (mkRule { product = "374b"; name = "stlinkv2-1"; })
          (mkRule { product = "3752"; name = "stlinkv2-1"; })
          # ST-Link V3
          (mkRule { product = "374d"; name = "stlinkv3loader"; })
          (mkRule { product = "374e"; name = "stlinkv3"; })
          (mkRule { product = "374f"; name = "stlinkv3"; })
          (mkRule { product = "3753"; name = "stlinkv3"; })
          (mkRule { product = "3754"; name = "stlinkv3"; })

        ];
      };
}
