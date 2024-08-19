{ config, lib, ... }:

with lib; let
  cfg = config.profiles.terminal;
in
{
  imports = [
    ./zsh.nix
  ];

  options.profiles.terminal = with types;{
    font = mkOption {
      type = uniq str;
      default = "Berkeley Mono";
      example = "Berkeley Mono";
      description = "The font family to use in the terminal.";
    };
    padding = {
      x = mkOption {
        type = int;
        default = 30;
        example = 30;
        description = "Terminal window x-padding, in pixels (if supported)";
      };
      y = mkOption {
        type = int;
        default = 30;
        example = 30;
        description = "Terminal window y-padding, in pixels (if supported)";
      };
    };
  };

  config = mkMerge [
    (mkIf config.programs.alacritty.enable {
      programs.alacritty = {
        settings = {
          # Configuration for Alacritty, the GPU enhanced terminal emulator
          # Live config reload (changes require restart)
          live_config_reload = true;
          window = {
            dynamic_title = true;
            # Window dimensions in character columns and lines
            # (changes require restart)
            dimensions = {
              columns = 120;
              lines = 80;
            };

            # Adds this many blank pixels of padding around the window
            # This is DPI-aware.
            # (change requires restart)
            padding = {
              x = cfg.padding.x;
              y = cfg.padding.y;
            };

            # Window decorations
            # Setting this to false will result in window without borders and title bar.
            # decorations: false
            decorations_theme_variant = "Dark";
            class = {
              instance = "Alacritty";
              general = "Alacritty";
            };
          };

          cursor = {
            style = {
              blinking = "On";
              shape = "Block";
            };
          };

          # When true, bold text is drawn using the bright variant of colors.
          colors.draw_bold_text_with_bright_colors = true;

          # Font configuration for alacritty (changes require restart)
          font = {
            # Point size of the font
            size = 13;
            # The normal (roman) font face to use.
            normal = {
              family = cfg.font;
              style = "Regular";
            };

            bold = {
              family = cfg.font;
              style = "Bold";
            };

            italic = {
              family = cfg.font;
              style = "Italic";
            };
          };
        };
      };
    })
    (mkIf config.programs.wezterm.enable (
      let waylandGnomeScript = "wayland-gnome"; in {
        programs.wezterm = {
          enableZshIntegration = true;
          enableBashIntegration = true;
          extraConfig = ''
            -- Pull in the wezterm API
            local wezterm = require 'wezterm'

            -- This will hold the configuration.
            local config = wezterm.config_builder()

            config.font = wezterm.font '${cfg.font}'
            config.harfbuzz_features = { 'calt=1', 'clig=1', 'liga=1' }

            -- Window padding
            config.window_padding = {
              top = '${toString cfg.padding.y}px',
              bottom = '${toString cfg.padding.y}px',
              left = '${toString cfg.padding.x}px',
              right = '${toString cfg.padding.x}px',
            }

            config.enable_tab_bar = true
            config.hide_tab_bar_if_only_one_tab = true
            config.window_frame = {
              -- The overall background color of the tab bar when
              -- the window is focused
              active_titlebar_bg = '#242424',

              -- The overall background color of the tab bar when
              -- the window is not focused
              inactive_titlebar_bg = '#242424',
            }

            local ${waylandGnomeScript} = require '${waylandGnomeScript} '
            ${waylandGnomeScript}.apply_to_config(config)

            return config
          '';
        };
        xdg.configFile."wezterm/${waylandGnomeScript}.lua".source = ./wezterm/wayland-gnome.lua;
      }
    )
    )
  ];
}
