{ config, lib, pkgs, ... }:
let cfg = config.hardware.probes;
in with lib; {
  options.hardware.probes = {
    st-link.enable = mkEnableOption "udev rules for ST-Link debug probes";
    cmsis-dap.enable = mkEnableOption "udev rules for CMSIS-DAP debug probes (such as NXP MCU-Link)";
    espressif.enable = mkEnableOption "udev rules for Espressif USB JTAG/serial debug units";
    ftdi.enable = mkEnableOption "udev rules for FTDI UART dongles";
  };

  config =
    let
      # only match USB devices
      subsystem = ''SUBSYSTEM=="usb"'';
      mkVendorId = (vendor: ''ATTR{idVendor}=="${vendor}"'');
      mkProductId = (product: ''ATTR{idProduct}=="${product}"'');
      mkNumberedSymlink = (name: ''SYMLINK+="${name}_%n"'');
      rulesPath = "/lib/udev/rules.d";
      mode = ''MODE:="0666"'';
      uaccess = ''TAG+="uaccess"'';
    in
    mkMerge ([
      { }
      (mkIf cfg.cmsis-dap.enable (
        let
          rules = pkgs.writeTextFile
            rec {
              name = "49-cmsis-dap.rules";
              text = ''
                # NXP MCU-Link --- give it a nicer symlink
                ${subsystem}, ${mkVendorId "1fc9"}, ${mkProductId "0143"}, ${mode}, ${uaccess}, ${mkNumberedSymlink "mcu-link"}
                # CMSIS-DAP compatible adapters
                ${subsystem}, ATTRS{product}=="*CMSIS_DAP*", ${mode}, ${uaccess}, ${mkNumberedSymlink "cmsis-dap"}
                # Some CMSIS-DAP devices have an underscore in the product name,
                # and others have a dash. You love to see it :/
                ${subsystem}, ATTRS{product}=="*CMSIS-DAP*", ${mode}, ${uaccess}, ${mkNumberedSymlink "cmsis-dap"}
                # WCH Link (CMSIS-DAP compatible adapter)
                ${subsystem}, ${mkVendorId "1a86"}, ${mkProductId "8011"}, ${mode}, ${uaccess}, ${mkNumberedSymlink "wch-link"}
              '';
              destination = "${rulesPath}/${name}";
            };
        in
        {
          services.udev.packages = [ rules ];
        }
      ))
      (mkIf cfg.espressif.enable (
        let
          vendor = mkVendorId "303a";
          rules = pkgs.writeTextFile
            rec {
              name = "49-espressif-debug.rules";
              text = ''
                # Espressif USB JTAG/serial debug unit
                ${subsystem}, ${vendor}, ${mkProductId "1001"}, ${mode}, ${uaccess}, ${mkNumberedSymlink "esp32-jtag"}
                # Espressif USB bridge
                ${subsystem}, ${vendor}, ${mkProductId "1002"}, ${mode}, ${uaccess}, ${mkNumberedSymlink "esp32-bridge"}
              '';
              destination = "${rulesPath}/${name}";
            };
        in
        {
          services.udev.packages = [ rules ];
        }
      ))
      (mkIf cfg.st-link.enable (
        let
          vendor = mkVendorId "0483";
          mkRule = { product, name }:
            (
              ''
                ${subsystem}, ${vendor}, ${mkProductId product}, ${mode}, ${uaccess}, ${mkNumberedSymlink name}
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
          v3Rules = pkgs.writeTextFile
            rec {
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
        {
          services.udev.packages = [ v2Rules v2_1Rules v3Rules ];
        }
      ))
      (mkIf cfg.ftdi.enable (
        let
          vendor = mkVendorId "0403";
          subsystemTty = ''SUBSYSTEM=="tty"'';
          rules = pkgs.writeTextFile
            {
              name = "49-ftdi.rules";
              text = concatStrings [
                ''
                  ACTION=="remove", GOTO="ftdi_usb_uart_end"
                  SUBSYSTEM!="tty", GOTO="ftdi_usb_uart_end"
                  ${subsystemTty}, ${vendor}, ${mode}, ${uaccess}, ${mkNumberedSymlink "tty%E{ID_MODEL}"}, SYMLINK+="ttyFTDI_%E{ID_SERIAL_SHORT}"
                  LABEL="ftdi_usb_uart_end"
                ''
              ];
            };
        in
        {
          services.udev.packages = [ rules ];
        }
      ))
    ]);
}
