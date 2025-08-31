{ config, pkgs, lib, ... }:
let
  cfg = config.programs.zsh;
in
with lib; {
  config = mkIf cfg.enable {
    programs = {
      # enable zsh integration options on other packages
      direnv.enableZshIntegration = true;
      keychain.enableZshIntegration = true;
      starship.enableZshIntegration = true;

      alacritty.settings.shell.program = "zsh";

      # zsh config
      zsh = {
        syntaxHighlighting.enable = true;
        # Whether to enable integration with terminals using the VTE library.
        # This will let the terminal track the current working directory.
        enableVteIntegration = true;
        autocd = true;
        history = {
          ignoreDups = true;
          share = true;
        };

        initContent = mkMerge [
          (lib.mkOrder 1000 (builtins.readFile ./titlePrecmd.zsh))
          (lib.mkOrder 1001 (builtins.readFile ./walColors.zsh))
        ];


        ### nicer autocomplete ###
        # these has to be explicitly disabled for things to work nicely
        enableCompletion = false;
        autosuggestion.enable = false;
        plugins = [{
          # will source zsh-autocomplete.plugin.zsh
          name = "zsh-autocomplete";
          src = pkgs.zsh-autocomplete;
        }];

        # aliases
        shellAliases = {
          # im a dumbass
          cagro = "cargo";
          carg = "cargo";
          gti = "git";
        };
      };
    };
  };
}
