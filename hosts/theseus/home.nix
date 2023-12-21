{ config, pkgs, lib, ... }:

{
  profiles = {
    gnome3.enable = true;
  };
  
  #############################################################################
  ## Programs                                                                 #
  #############################################################################
  programs = {
    _1password-gui.enableSshAgent = true;
  };
}
