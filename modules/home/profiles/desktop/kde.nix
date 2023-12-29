{ config, lib, ... }:

let cfg = config.profiles.desktop.kde;
in {

  options.profiles.desktop.kde = with lib; {
    enable = mkEnableOption "KDE profile";
  };

  config = lib.mkIf cfg.enable {
    # programs = {
    #   # enable gpaste, a gnome clipboard manager.
    #   gpaste.enable = true;
    # };
  };

}
