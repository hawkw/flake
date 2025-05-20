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
          xan
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
              color = {
                when = "auto";
                # theme = "custom";
              };
              # use unicode icons rather than fontawesome or whatever (for
              # compatibility).
              icons = {
                when = "auto";
                # # apparently lsd will only honor custom icon overrides when the
                # # theme is set to "fancy" rather than "unicode", which the
                # # documentation does not indicate but seems to be the case. see:
                # # https://github.com/lsd-rs/lsd/issues/1082#issuecomment-2411590702
                # #
                # # we intend to only use unicode characters as icons. however, we
                # # must select the "fancy" (i.e., nerd fonts) theme in order to
                # # change the unicode characters from the default. this is weird
                # # and surprising, but it seems to work.
                # theme = "fancy";
                theme = "unicode";
                separator = " ";
              };

              hyperlink = "never";
            };
          };

          zoxide = { enable = true; };
        };

        xdg.configFile."lsd/icons.yaml".source = (pkgs.formats.yaml { }).generate "icons.yaml"
          {
            name = { };
            extension = { };
            filetype = {
              dir = "🗁";
              file = "🗎";
              executable = "🗔";
              pipe = "⭍";
              socket = "🖧";
              symlink-dir = "🗂";
              simlink-file = "🗐";
              device-block = "🖴";
              device-char = "🖵";
              special = "🖭";
            };
          };
        # alternative LSD icons using all emojis
        # xdg.configFile."lsd/icons.yaml".source = (pkgs.formats.yaml { }).generate "icons.yml"
        #   {
        #     filetype = {
        #       dir = "📂";
        #       file = "📄";
        #       executable = "📝";
        #       pipe = "📨";
        #       socket = "📡";
        #       symlink-dir = "🔗";
        #       simlink-file = "📑";
        #       device-block = "💽";
        #       device-char = "📟";
        #       special = "📼";
        #     };
        #   };
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
        home.shellAliases = {
          tree = "${pkgs.lsd}/bin/lsd --tree";
          grep = "${pkgs.ripgrep}/bin/rg";
        };
      })
    ]);
}
