#
# Terminal emulator configuration.
#
# This module contains configs for terminal emulator programs. At
# present, it supports WezTerm and Alacritty.
#
{ config, lib, ... }:

with lib; let
  cfg = config.profiles.terminal;
in
{
  options.profiles.terminal = with types; {
    font = {
      family = mkOption {
        type = uniq str;
        default = "Berkeley Mono";
        example = "Berkeley Mono";
        description = "The font family to use in the terminal.";
      };
      sizePt = mkOption {
        type = int;
        default = 13;
        example = 12;
        description = "The font size in points to use in the terminal.";
      };
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
    (mkIf config.programs.alacritty.enable (
      let
        fixTermEnvVar = ''
          # alacritty misuses TERM and sets it to its own name, but does not
          # set TERM_PROGRAM. this causes issues when using software that
          # attempts to detect whether the terminal supports colors using
          # TERM, which is not *really* supposed to be the name of the terminal
          # emulator. in particular, this happens on SSH connections a lot,
          # because the COLORTERM env var usually isn't propagated by sshd, but
          # TERM is, making it the only way for software on the remote to detect
          # terminal capabilities.
          if [[ "$TERM" == alacritty* ]]; then
            export TERM_PROGRAM="$TERM"
            export TERM="xterm-256color"
          fi
        '';
      in
      mkMerge [
        {
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
                size = cfg.font.sizePt;
                # The normal (roman) font face to use.
                normal = {
                  family = cfg.font.family;
                  style = "Regular";
                };

                bold = {
                  family = cfg.font.family;
                  style = "Bold";
                };

                italic = {
                  family = cfg.font.family;
                  style = "Italic";
                };
              };
            };
          };
        }
        (mkIf config.programs.zsh.enable {
          programs.zsh.initExtra = fixTermEnvVar;
        })
        (mkIf config.programs.bash.enable {
          programs.bash.initExtra = fixTermEnvVar;
        })
      ]
    ))
    (mkIf config.programs.wezterm.enable (
      let
        waylandGnomeScript = "wayland_gnome";
        bgColor = "#242424";
      in
      {
        programs.wezterm = {
          enableZshIntegration = true;
          enableBashIntegration = true;
          extraConfig = ''
            -- Pull in the wezterm API
            local wezterm = require 'wezterm'

            -- This will hold the configuration.
            local config = wezterm.config_builder()

            config.font = wezterm.font_with_fallback {
              '${cfg.font.family}',
              -- Prefer monochrome emoji
              { family = 'Noto Emoji', assume_emoji_presentation = true },
            }
            config.font_size = ${toString cfg.font.sizePt}.0
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
              font = wezterm.font { family = '${cfg.font.family}', weight = 'Bold', },
              font_size = ${toString cfg.font.sizePt}.0,

              -- The overall background color of the tab bar when
              -- the window is focused
              active_titlebar_bg = '${bgColor}',

              -- The overall background color of the tab bar when
              -- the window is not focused
              inactive_titlebar_bg = '${bgColor}',
            }

            -- This config appears to make the mouse cursor disappear whenever
            -- it's over a Wezterm window, not just when actively typing, at
            -- least on my system (GNOME3 on Wayland). This makes it impossible
            -- to use the mouse to select text in the terminal, which is
            -- borderline unusable.
            config.hide_mouse_cursor_when_typing = false

            config.ssh_domains = {
              {
                -- This name identifies the domain
                name = 'noctis',
                -- The hostname or address to connect to. Will be used to match settings
                -- from your ssh config file
                remote_address = 'noctis',
                -- The username to use on the remote host
                username = 'eliza',
              },
            }
            local ${waylandGnomeScript} = require '${waylandGnomeScript}'
            ${waylandGnomeScript}.apply_to_config(config)

            return config
          '';
        };
        xdg.configFile."wezterm/${waylandGnomeScript}.lua".source = ./wezterm/wayland_gnome.lua;
      }
    )
    )
  ];
}
