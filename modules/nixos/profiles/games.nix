{ config, lib, pkgs, ... }:
let cfg = config.profiles.games;
in {
  options.profiles.games = with lib; {
    enable = mkEnableOption "games profile";
  };

  config = lib.mkIf cfg.enable {
    # some steam games need 32-bit driver support
    services.pulseaudio.support32Bit = true;
    hardware = {
      graphics = {
        extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
        enable32Bit = true;
      };
    };

    programs.steam.enable = true;
  };
}
