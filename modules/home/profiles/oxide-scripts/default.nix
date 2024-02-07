{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.oxide-scripts;

  zshEnabled = config.programs.zsh.enable;
in
with lib; {
  options.profiles.oxide-scripts = {
    enable = mkEnableOption "Profile with shell scripts for syncing with Oxide lab hosts";
  };

  config = mkIf cfg.enable
    (mkMerge [
      # always add the Oxide profile scripts.
      {
        home.packages = with pkgs;
          let
            atrium-sync = writeShellApplication
              {
                name = "atrium-sync";
                runtimeInputs = [ rsync ];
                text = builtins.readFile ./atrium-sync.sh;
              };
            atrium-run = writeShellApplication
              {
                name = "atrium";
                runtimeInputs = [ openssh rsync atrium-sync ];
                text = builtins.readFile ./atrium-run.sh;
              };
          in
          [ atrium-sync atrium-run ];
      }
      # if ZSH is enabled, add the env var that tells Omicron to use flakes.
      (mkIf zshEnabled {
        programs.zsh.sessionVariables = {
          # Tell direnv to opt in to using the Nix flake for Omicron.
          OMICRON_USE_FLAKE = "1";
        };
      })
    ]
    );
}
