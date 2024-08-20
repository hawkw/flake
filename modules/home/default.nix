{ config, pkgs, lib, ... }:

let
  user = {
    name = "Eliza Weisman";
    email = "eliza@elizas.website";
  };
in
rec {
  imports = [
    ./fonts.nix
    ./ssh.nix
    ./profiles
    ./programs
  ];

  home.stateVersion = "23.11";

  # https://github.com/nix-community/home-manager/issues/3342
  manual.manpages.enable = false;

  home = {
    sessionVariables = {
      EDITOR = "code --wait";
      BROWSER = "firefox";
      TERMINAL = "alacritty";
    };

    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.linkerd2/bin"
    ];

    packages = with pkgs; [
      ### networking tools ##
      nmap
      slurm
      bandwhich
      nghttp2
      inetutils
      # assorted wiresharks
      termshark
      tcpdump

      ### stuff ###
      neofetch
      pfetch
      fastfetch
      dtrx # Do The Right eXtraction --- extract any kind of archive file
      unzip
      btop

      asciinema

      ### "crypto" ###
      gnupg
    ];
  };

  # automagically add zsh completions from packages
  xdg.configFile."zsh/vendor-completions".source = with pkgs;
    runCommandNoCC "vendored-zsh-completions" { } ''
      mkdir -p $out
      ${fd}/bin/fd -t f '^_[^.]+$' \
        ${lib.escapeShellArgs home.packages} \
        | xargs -0 -I {} bash -c '${ripgrep}/bin/rg -0l "^#compdef" $@ || :' _ {} \
        | xargs -0 -I {} cp -t $out/ {}
    '';

  # configure discord to launch even when an update is available

  #############################################################################
  ## Programs                                                                 #
  #############################################################################
  # my custom config modules
  profiles = {
    # use a collection of Rust versions of common unix utilities.
    rustyUtils = {
      enable = lib.mkDefault true;
      enableAliases = lib.mkDefault true;
    };

    nix-tools = {
      enable = lib.mkDefault true;
      # these are broken :(
      enableNomAliases = lib.mkDefault false;
    };

    # custom git configs
    git = {
      enable = lib.mkDefault true;
      user = {
        name = user.name;
        email = user.email;
      };
    };
  };

  programs = {
    alacritty.enable = lib.mkDefault true;
    wezterm.enable = lib.mkDefault true;

    nushell = {
      enable = lib.mkDefault true;
      configFile.text = ''
        let $config = {
          pivot_mode: always
          nonzero_exit_errors: true
          use_ls_colors: true
          table_mode: rounded
        };
      '';
    };

    zellij.enable = lib.mkDefault true;

    starship = {
      enable = true;
      settings = {
        # Replace the "❯" symbol in the prompt with ":;"

        # why use ":;" as the prompt character? it is a no-op in most (all?) unix shells, so copying and
        # pasting a command including the prompt character will still work
        character = {
          success_symbol = "[\\$](bold green)";
          error_symbol = "[\\$](bold red)";
        };

        hostname = {
          format = "@[$hostname]($style)";
          ssh_only = false;
        };

        username = {
          format = "[$user]($style)";
          show_always = true;
        };

        directory = {
          truncate_to_repo = false;
          truncation_length = 5;
          truncation_symbol = "…/";
        };

        direnv = {
          disabled = false;
          symbol = "env ";
          format = "$symbol[$loaded$allowed]($style) ";
          style = "bold blue";
          allowed_msg = "";
          not_allowed_msg = " (not allowed)";
        };

        # nodejs.disabled = true;

        kubernetes = {
          # disabled = false;
          format = "on [$symbol$context(\\($namespace\\))]($style) ";
          context_aliases = {
            # OpenShift contexts carry the namespace and user in the kube context: `namespace/name/user`:
            ".*/(?P<var_cluster>[\\w-]+)/.*" = "$var_cluster";

            # Contexts from GKE, AWS and other cloud providers usually carry additional information, like the region/zone.
            # The following entry matches on the GKE format (`gke_projectname_zone_cluster-name`)
            # and renames every matching kube context into a more readable format (`gke-cluster-name`):
            "gke_.*_(?P<var_cluster>[\\w-]+)" = "gke-$var_cluster";
          };
          # detect_files = [ "*.yml" "*.yaml" ];
          detect_folders = [ "linkerd2" "linkerd2-proxy" ];
        };

        rust = {
          symbol = "⚙️ ";
          # i don't like "via" as a way to state the toolchain version.
          format = "using [$symbol($version )]($style)";
        };

        # package.symbol = "";

        # unfortunately, the `sudo` module for starship doesn't work nicely with
        # sudo-rs :(
        # TODO(eliza): sudo-rs.enable is part of the NixOS config, not
        # home-manager...
        # sudo.disabled = config.security.sudo-rs.enable;
        sudo.disabled = true;

        nix_shell = {
          symbol = "❄️ ";
          impure_msg = "[\\(]($style)[±](bold red)[\\)]($style)";
          pure_msg = "";
          format = "in [$symbol$name$state]($style) ";
          # heuristic = true;
        };

        time = {
          disabled = false;
          # style = "bold fg:bright-black bg:green";
          format = "⏲ [$time]($style) ";
        };

        git_branch = {
          # Unicode "alternative key symbol" works nicely as a "git branch"
          # symbol but doesn't require patched fonts.
          symbol = "⎇  ";
        };

        status = {
          disabled = false;
          map_symbol = true;
          pipestatus = true;
          # symbol = "❌";
          not_executable_symbol = "🚫";
          sigint_symbol = "❗";
          not_found_symbol = "❓";
        };

        format = lib.concatStrings [
          # Start the first line with a shell comment so that the entire prompt
          # can be copied and pasted.
          "[#](hidden)"
          # "[](fg:black bg:green)"
          # "[ ](bg:green)"
          "$time"
          # "[](fg:green) "
          # "[](bg:#DA627D fg:#9A348E)"
          "$direnv"
          "$nix_shell"
          # "[](fg:#DA627D bg:#FCA17D)"
          "$git"
          # "[](fg:#FCA17D bg:#86BBD8)"
          "$all"
          "$kubernetes"
          # "[](fg:#86BBD8 bg:#06969A)"
          "$cmd_duration"
          "$status"
          "$line_break"
          "$username"
          "$hostname"
          " "
          "$directory"
          "$character"
        ];

      };
    };

    htop = {
      enable = lib.mkDefault true;
      # settings = {
      #   highlight_base_name = true;
      #   highlight_threads = true;
      #   tree_view = true;
      #   # showThreadNames = true;
      #   # on NixOS, pretty much every path starts with /nix/store/(LONG SHA).
      #   # Because of that, when the whole path is shown, you need a really
      #   # wide terminal window, or else the program names are not really
      #   # readable. So let's turn off paths.
      #   show_program_path = false;
      #   # This is rarely useful but it's cool to see, if you're me.
      #   hide_kernel_threads = false;
      #   show_custom_thread_names = true;
      #   highlight_new_and_old_processes = true;
      #   left_meters = [
      #     "Hostname"
      #     "Uptime"
      #     "Tasks"
      #     "LoadAverage"
      #     "Systemd"
      #     "Blank"
      #     "NetworkIO"
      #     "DiskIO"
      #   ];
      #   # I have entirely too many cores for the default meter configuration to
      #   # be useable. :)
      #   right_meters = [ "AllCPUs2" "Blank" "Memory" "Swap" ];
      # };
    };

    tmux = {
      enable = lib.mkDefault true;
      plugins = with pkgs.tmuxPlugins; [
        sensible
        cpu
        continuum
        prefix-highlight
        yank
      ];
      extraConfig = ''
        # Status bar settings adapted from powerline
        set -g status on
        set -g status-interval 10
        set -g status-fg white
        set -g status-bg black
        set -g status-left-length 20
        set -g status-left '#{?client_prefix,#[fg=default]#[bg=red]#[bold],#[fg=red]#[bg=black]#[bold]} #S #{?client_prefix,#[fg=red]#[bg=magenta]#[nobold],#[fg=black]#[bg=magenta]#[nobold]}'
        set -g status-right '#(eval cut -c3- ~/.tmux.conf | sh -s status_right) #h '
        set -g status-right-length 150
        set -g window-status-format "#[fg=black,bg=red]#I #[fg=colour240] #[default]#W "
        set -g window-status-current-format "#[fg=b,bg=blue]#[fg=black,bg=blue] #I  #[fg=black]#W #[fg=blue,bg=black,nobold]"
        set -g window-status-last-style fg=white

        # ENDOFCONF
        # status_right() {
        #   cols=$(tmux display -p '#{client_width}')
        #   if (( $cols >= 80 )); then
        #     hoststat=$(hash tmux-mem-cpu-load && tmux-mem-cpu-load -i 10 || uptime | cut -d: -f5)
        #     echo "#[fg=colour233,bg=default,nobold,noitalics,nounderscore]#[fg=colour247,bg=colour233,nobold,noitalics,nounderscore] ⇑ $hoststat #[fg=colour252,bg=colour233,nobold,noitalics,nounderscore]#[fg=colour16,bg=colour252,bold,noitalics,nounderscore]"
        #   else
        #     echo '#[fg=colour252,bg=colour233,nobold,noitalics,nounderscore]#[fg=colour16,bg=colour252,bold,noitalics,nounderscore]'
        #   fi
        # }
        # clone () {
        #   orig=''${1%-*}
        #   let i=$( tmux list-sessions -F '#S' | sed -nE "/^''${orig}-[0-9]+$/{s/[^0-9]//g;p}" | tail -n1 )+1
        #   copy="$orig-$i"
        #   TMUX= tmux new-session -d -t $orig -s $copy
        #   tmux switch-client -t $copy
        #   tmux set -q -t $copy destroy-unattached on
        # }
        # $@
        # # vim: ft=tmux
      '';
    };


    ssh = { enable = true; };
  };

  # atuin --- enable the Atuin daemon as well as the program and its config.
  programs.atuin = {
    enable = lib.mkDefault true;
    settings = {
      dialect = "us";
      auto_sync = true;
      daemon.enabled = lib.mkDefault true;
    };
  };
  # Running the daemon should fix ZFS-related issues.
  # See: https://github.com/atuinsh/atuin/issues/952
  #
  # This systemd unit config is based on the one from this thread:
  # https://forum.atuin.sh/t/getting-the-daemon-working-on-nixos/334
  systemd.user.services.atuind = {
    Unit = {
      Description = "Atuin daemon";
      After = [ "network.target" ];
    };
    Service = {
      Environment = [ "ATUIN_LOG=info" ];
      ExecStart = "${pkgs.atuin}/bin/atuin daemon";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

}
