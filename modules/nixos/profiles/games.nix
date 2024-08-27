{ config, lib, pkgs, ... }:
let cfg = config.profiles.games;
in {
  options.profiles.games = with lib; {
    enable = mkEnableOption "games profile";
  };

  config = lib.mkIf cfg.enable {
    hardware = {
      # some steam games need 32-bit driver support
      pulseaudio.support32Bit = true;
      graphics = {
        extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
        enable32Bit = true;
      };
    };

    programs.steam.enable = true;
  };
}
