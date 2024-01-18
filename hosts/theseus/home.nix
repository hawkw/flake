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
  };

  # not trying to build ESP32-C3 on this machine, so global clang is fine...
  home.packages = with pkgs; [ clang qemu screen ];
}
