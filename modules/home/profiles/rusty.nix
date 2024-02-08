{ config, pkgs, lib, ... }:

let cfg = config.profiles.rustyUtils;
in with lib; {
  options = {
    profiles.rustyUtils = {
      enable = mkEnableOption "rusty unix utils";
      enableAliases = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  config =
    let
      mcflyEnabled = config.programs.mcfly.enable;
      # zellijEnabled = config.programs.zellij.enable;
      # which shells are enabled?
      zshEnabled = config.programs.zsh.enable;
      bashEnabled = config.programs.bash.enable;
      fishEnabled = config.programs.fish.enable;
    in
    mkIf cfg.enable (mkMerge [
      {
        home.packages = with pkgs; [
          tokei
          xsv
          ripgrep
          fd
          # ytop
          bottom
          glances
          # dust: like `du` but good
          du-dust
          # procs: list processes
          procs
        ];

        programs = {
          bat = { enable = true; };
          broot = {
            enable = true;
            settings.verbs = [{
              name = "view";
              invocation = "view";
              key = "enter";
              execution = "bat {file}";
              leave_broot = false;
              apply_to = "file";
            }];
          };

          # exa: a (non-backwards-compatible) ls-like tool
          eza = { enable = true; };
          # lsd: a backwards compatible `ls` replacement
          lsd = {
            enable = true;
            settings = {
              icons = {
                when = "auto";
                # use unicode icons rather than fontawesome or whatever (for compatibility).
                # theme = "unicode";
                separator = "  ";
              };
            };
          };

          zoxide = { enable = true; };
        };
      }

      # mcfly: shell history (ctrl-r) replacement
      (mkIf mcflyEnabled (mkMerge [
        { programs.mcfly = { enableFuzzySearch = true; }; }

        (mkIf zshEnabled { programs.mcfly.enableZshIntegration = true; })
        (mkIf bashEnabled { programs.mcfly.enableBashIntegration = true; })
        (mkIf fishEnabled { programs.mcfly.enableFishIntegration = true; })
      ]))

      # If aliases are enabled, alias common unix utils with their rustier replacements.
      (mkIf cfg.enableAliases {
        programs.lsd.enableAliases = true;
        home.shellAliases = {
          tree = "${pkgs.lsd}/bin/lsd --tree";
          grep = "${pkgs.ripgrep}/bin/rg";
        };
      })
    ]);
}
