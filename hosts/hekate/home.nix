{ pkgs, ... }:

{
  profiles = {
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
    devtools = {
      enable = true;
      enablePython = true;
    };
    oxide = {
      enable = true;
    };
    opstools = {
      enable = true;
      net.enable = true;
      supermicro.enable = true;
    };
  };

  home.packages = with pkgs; [
    # global pkgconfig too
    pkg-config
  ];

  services = {
    gpg-agent = {
      enable = true;
      # pinentryFlavor = "gnome3";
    };
  };
}
