{ config, pkgs, lib, ... }:

{
  profiles = {
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
  };
}
