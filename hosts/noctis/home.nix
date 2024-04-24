{ pkgs, ... }:

{
  profiles = {
    games.enable = true;
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
    k8s.enable = true;
    devtools = {
      enable = true;
      enablePython = true;
    };
    oxide = {
      enable = true;
    };
  };

  home.packages = with pkgs; [ sensors wally-cli conky ];

  services = {
    gpg-agent = {
      enable = true;
      pinentryFlavor = "gnome3";
    };
  };
}
