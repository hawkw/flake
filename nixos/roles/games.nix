{ config, lib, pkgs, ... }:

{
  hardware = {
    # some steam games need 32-bit driver support
    pulseaudio.support32Bit = true;
    opengl = {
      extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
      driSupport32Bit = true;
    };
  };

  programs.steam.enable = true;
}
