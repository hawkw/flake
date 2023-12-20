{ config, pkgs, lib, ... }:

{
  profiles = {
    games.enable = true;
    gnome3.enable = true;
    k8s.enable = true;
  };
  home.packages = with pkgs; [ lm_sensors wally-cli conky ];
  #############################################################################
  ## Services                                                                 #
  #############################################################################
  services = {
    gpg-agent = {
      enable = true;
      pinentryFlavor = "gnome3";
    };
    kbfs.enable = true;
    keybase.enable = true;
  };

  #############################################################################
  ## Programs                                                                 #
  #############################################################################
  programs = {
    keychain = {
      enable = true;
      enableXsessionIntegration = true;
      keys = [ "id_ed25519" ];
    };
    _1password-gui.enableSshAgent = true;
  };
}
