{ config, pkgs, lib, ... }:

{
  profiles = {
    games.enable = true;
    destkop = {
      enable = true;
      gnome3.enable = true;
    };
    k8s.enable = true;
  };

  home.packages = with pkgs; [ lm_sensors wally-cli conky ];

  services = {
    gpg-agent = {
      enable = true;
      pinentryFlavor = "gnome3";
    };
  };
}
