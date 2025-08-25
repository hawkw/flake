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
    # not trying to build ESP32-C3 on this machine, so global clang is fine...
    clang
    # global pkgconfig too
    pkg-config
    qemu
    screen
  ];


  services = {
    gpg-agent = {
      enable = true;
      # pinentryFlavor = "gnome3";
    };
  };
}
