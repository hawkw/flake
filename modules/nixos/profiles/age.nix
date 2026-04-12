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
        environment.systemPackages = [ pkgs.rage ];
      }
      # If 1Password is enabled, add the 1password age plugin.
      (mkIf config.programs._1password.enable {
        environment.systemPackages = [ pkgs.age-plugin-1p ];
      })
    ]
  );
}
