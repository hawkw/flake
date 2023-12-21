{ config, pkgs, lib, ... }:

let
  cfg = config.programs.xfel;
  xfel = pkgs.xfel;
in with lib; {
  options = { programs.xfel.enable = mkEnableOption "XFEL"; };
  config = mkIf cfg.enable {
    services.udev.packages = [ xfel ];
    environment.systemPackages = [ xfel ];
  };
}
