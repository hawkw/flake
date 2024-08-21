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
        enableVteIntegration = true;
        autocd = true;
        history = {
          ignoreDups = true;
          share = true;
        };

        initExtra = ''
          # xterm title setting stuff
          autoload -Uz add-zsh-hook

          function xterm_title_precmd () {
            print -Pn -- '\e]2;%n@%m %~\a'
            [[ "$TERM" == 'screen'* ]] && print -Pn -- '\e_\005{g}%n\005{-}@\005{m}%m\005{-} \005{B}%~\005{-}\e\\'
          }

          function xterm_title_preexec () {
            print -Pn -- '\e]2;%n@%m %~ %# ' && print -n -- "''${(q)1}\a"
            [[ "$TERM" == 'screen'* ]] && { print -Pn -- '\e_\005{g}%n\005{-}@\005{m}%m\005{-} \005{B}%~\005{-} %# ' && print -n -- "''${(q)1}\e\\"; }
          }

          if [[ "$TERM" == (Eterm*|alacritty*|aterm*|gnome*|konsole*|kterm*|putty*|rxvt*|screen*|tmux*|xterm*) ]]; then
            add-zsh-hook -Uz precmd xterm_title_precmd
            add-zsh-hook -Uz preexec xterm_title_preexec
          fi

          # test if SSH connection
          if [ -n "''${SSH_CLIENT}" ] || [ -n "''${SSH_TTY}" ]; then
            SESSION_TYPE=remote/ssh
          else
            case $(ps -o comm= -p "''${PPID}") in
              sshd|*/sshd) SESSION_TYPE=remote/ssh;;
            esac
          fi

          # Import colorscheme from 'wal' asynchronously, if the terminal is
          # alacritty, and the current session is not a SSH session.
          if [[ -z ''${SESSION_TYPE+x} ]]; then
            (cat "''${HOME}/.cache/wal/sequences" &)
          fi
        '';


        ### nicer autocomplete ###
        # these has to be explicitly disabled for things to work nicely
        enableCompletion = false;
        autosuggestion.enable = false;
        plugins = [{
          # will source zsh-autocomplete.plugin.zsh
          name = "zsh-autocomplete";
          src = pkgs.fetchFromGitHub {
            owner = "marlonrichert";
            repo = "zsh-autocomplete";
            rev = "23.07.13";
            sha256 = "sha256-0NW0TI//qFpUA2Hdx6NaYdQIIUpRSd0Y4NhwBbdssCs=";
          };
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
