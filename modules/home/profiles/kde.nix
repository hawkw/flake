{ config, pkgs, lib, ... }:

let cfg = config.profiles.kde;
in {
  options.profiles.kde = with lib; { enable = mkEnableOption "KDE profile"; };
  programs = {
    # enable gpaste, a gnome clipboard manager.
    gpaste.enable = true;
  };
}
