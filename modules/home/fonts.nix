{ pkgs, ... }:

{
  fonts.fontconfig.enable = true;

  # fonts
  home.packages = with pkgs; [
    # nice monospace and bitmap fonts
    iosevka
    cozette
    tamzen
    departure-mono
    # tamsyn
    nerdfonts
    # requires `input-fonts.acceptLicense = true` in `config.nix`.
    input-fonts

    # some nice ui fonts
    roboto
    inter
    b612 # designed by Airbus for jet cockpit UIs!

    # noto, and friends --- manish says its good
    # this fixes unicode tofu, even if you don't actually use
    # noto as a UI font...
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    noto-fonts-extra
    noto-fonts-monochrome-emoji
    # fontconfig binary
    fontconfig
  ];
}
