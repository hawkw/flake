{ pkgs, ... }:
# let
#   mkIosevkaEliza = { spacing, name }: pkgs.iosevka.override
#     {
#       privateBuildPlan = {
#         family = "Iosevka Eliza ${name}";
#         spacing = spacing;
#         serifs = "sans";
#         noCvSs = false;
#         exportGlyphNames = false;
#         variants = {
#           inherits = "ss08";
#           design = {
#             seven = "curly-serifless-crossbar";
#             brace = "curly";
#             number-sign = "upright";
#           };
#           ligations = {
#             inherits = "dlig";
#           };
#         };
#       };
#       set = "IosevkaEliza${name}";
#     };
#   iosevkaElizaTerm = mkIosevkaEliza { spacing = "term"; name = "Term"; };
#   iosevkaEliza = mkIosevkaEliza { spacing = "sans"; name = ""; };
#   iosevkaElizaEtoile = mkIosevkaEliza { spacing = "quasi-proportional"; name = "Etoile"; };
# in
{
  fonts.fontconfig.enable = true;

  # fonts
  home.packages = with pkgs; [
    # iosevka + variants
    iosevka-bin
    (iosevka-bin.override { variant = "Aile"; })
    (iosevka-bin.override { variant = "Etoile"; })
    (iosevka-bin.override { variant = "SS08"; }) # pragmatapro-style

    # nice monospace and bitmap fonts
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
