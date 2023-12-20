{ config, pkgs, lib, ... }:

let cfg = config.profiles.games;
in {
  options.profiles.games = with lib; {
    enable = mkEnableOption "games profile";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ minecraft technic-launcher ckan playonlinux ];
  };
}
