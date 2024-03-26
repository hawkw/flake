# udev rules for Ergodox keyboards
{ lib, config, pkgs, ... }:
let cfg = config.hardware.ergodox;
in with lib; {
  options.hardware.ergodox = { enable = mkEnableOption "Ergodox keyboard udev rules"; };

  config = mkIf cfg.enable (
    let
      vendorId = "feed";
      udevRules = pkgs.writeTextFile {
        name = "ergodox-udev-rules";
        text = ''
          # Rule for the Ergodox EZ Original / Shine / Glow
          SUBSYSTEM=="usb", ATTR{idVendor}=="${vendorId}", ATTR{idProduct}=="1307", TAG+="uaccess"
          # Rule for the Planck EZ Standard / Glow
          SUBSYSTEM=="usb", ATTR{idVendor}=="${vendorId}", ATTR{idProduct}=="6060", TAG+="uaccess"
        '';
        destination = "/etc/udev/rules.d/99-ergodox.rules";
      };

    in
    {
      services.udev.packages = [ udevRules ];
    }
  );
}
