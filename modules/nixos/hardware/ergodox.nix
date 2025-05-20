# udev rules for Ergodox keyboards
{ lib, config, pkgs, ... }:
let cfg = config.hardware.ergodox;
in with lib; {
  options.hardware.ergodox = { enable = mkEnableOption "Ergodox keyboard udev rules"; };

  config = mkIf cfg.enable (
    let
      vid-3297 = "3297";
      vid-feed = "feed";
      vid-16c0 = "16c0";
      group-plugdev = "plugdev";
      subsys-usb = "usb";
      udevRules = pkgs.writeTextFile {
        name = "zsa-udev-rules";
        text = ''
          # Rules for Oryx web flashing and live training
          KERNEL=="hidraw*", ATTRS{idVendor}=="${vid-16c0}", MODE="0664", GROUP="${group-plugdev}"
          KERNEL=="hidraw*", ATTRS{idVendor}=="${vid-3297}", MODE="0664", GROUP="${group-plugdev}"

          # Legacy rules for live training over webusb (Not needed for firmware v21+)
            # Rule for all ZSA keyboards
            SUBSYSTEM=="${subsys-usb}", ATTR{idVendor}=="${vid-3297 }", GROUP="${group-plugdev}"
            # Rule for the Moonlander
            SUBSYSTEM=="${subsys-usb}", ATTR{idVendor}=="${vid-3297}", ATTR{idProduct}=="1969", GROUP="${group-plugdev}"
            # Rule for the Ergodox EZ
            SUBSYSTEM=="${subsys-usb}", ATTR{idVendor}=="${vid-feed}", ATTR{idProduct}=="1307", GROUP="${group-plugdev}"
            # Rule for the Planck EZ
            SUBSYSTEM=="${subsys-usb}", ATTR{idVendor}=="${vid-feed}", ATTR{idProduct}=="6060", GROUP="${group-plugdev}"

          # Wally Flashing rules for the Ergodox EZ
          ATTRS{idVendor}=="${vid-16c0}", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
          ATTRS{idVendor}=="${vid-16c0}", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
          SUBSYSTEMS=="${subsys-usb}", ATTRS{idVendor}=="${vid-16c0}", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
          KERNEL=="ttyACM*", ATTRS{idVendor}=="${vid-16c0}", ATTRS{idProduct}=="04[789B]?", MODE:="0666"

          # Keymapp / Wally Flashing rules for the Moonlander and Planck EZ
          SUBSYSTEMS=="${subsys-usb}", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE:="0666", SYMLINK+="stm32_dfu"
          # Keymapp Flashing rules for the Voyager
          SUBSYSTEMS=="${subsys-usb}", ATTRS{idVendor}=="${vid-3297}", MODE:="0666", SYMLINK+="ignition_dfu"
        '';
        destination = "/etc/udev/rules.d/50-zsa.rules";
      };

    in
    {
      services.udev.packages = [ udevRules ];
      environment.systemPackages = with pkgs; [
        wally-cli
        keymapp
      ];
    }
  );
}
