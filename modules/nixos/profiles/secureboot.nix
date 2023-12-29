{ config, lib, pkgs, ... }:
let cfg = config.profiles.secureboot;
in {
  options.profiles.secureboot = with lib; {
    enable = mkEnableOption "secureboot profile (using lanzaboote)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      # For debugging and troubleshooting Secure Boot.
      pkgs.sbctl
    ];

    boot = {
      # Lanzaboote currently replaces the systemd-boot module.
      # This setting is usually set to true in configuration.nix
      # generated at installation time. So we force it to false
      # for now.
      loader.systemd-boot.enable = lib.mkForce false;

      lanzaboote = {
        enable = true;
        pkiBundle = "/etc/secureboot";
      };
    };
  };
}
