{ config, pkgs, lib, ... }:

let cfg = config.profiles.nix-tools;
in with lib; {
  options.profiles.nix-tools = {
    enable = mkEnableOption "Miscellaneous Nix tools";
  };

  config = mkIf cfg.enable
    (mkMerge [
      {
        home.packages = with pkgs; [
          nix-output-monitor
          nil
          nixpkgs-fmt
        ];

        programs.nix-index.enable = lib.mkDefault true;

        # this conflicts with `nix-index`, which is nicer imo
        # command-not-found.enable = true;
      }
      (mkIf config.programs.zsh.enable {
        programs.nix-index.enableZshIntegration = true;
      })
    ])
  ;
}
