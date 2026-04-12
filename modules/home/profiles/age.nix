{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.age;
in
with lib;
{
  options.profiles.age = {
    enable = mkEnableOption "configuration for Age encryption";
  };

  config = mkIf cfg.enable (
    mkMerge [
      {
        home.packages = [ pkgs.age ];
      }
      # If 1Password is enabled, add the 1password age plugin.
      (mkIf config.programs._1password.enable {
        home.packages = [ pkgs.age-plugin-1p ];
      })
    ]
  );
}
