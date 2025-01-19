{ pkgs, lib, ... }:

let
  user = {
    name = "Eliza Weisman";
    email = "eliza@elizas.website";
  };
in
rec {
  imports = [
    ./fonts.nix
    ./profiles
    ./programs
    ./shell
    ./ssh.nix
    ./terminal
  ];

  home.stateVersion = "23.11";

  # https://github.com/nix-community/home-manager/issues/3342
  manual.manpages.enable = false;

  home = {
    sessionVariables = {
      EDITOR = "code --wait";
      BROWSER = "firefox";
      TERMINAL = "alacritty";
      CARGO_TERM_COLOR = "auto";
      RUST_BACKTRACE = "1";
    };

    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.linkerd2/bin"
    ];

    packages = with pkgs; [
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

      iputils # ping, traceroute, etc.
    ];
  };
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

    # atuin --- enable the Atuin daemon as well as the program and its config.
    atuin = {
      enable = lib.mkDefault true;
      enableDaemon = lib.mkDefault true;
    };

    nushell.enable = lib.mkDefault true;
    zsh.enable = lib.mkDefault true;
    zellij.enable = lib.mkDefault true;
    starship.enable = lib.mkDefault true;

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

  # automagically add zsh completions from packages
  #
  # /!\ NOTE TO FUTURE ELIZAS /!\
  # You may, foolishly, attempt to move this into the `zsh.nix` module. Don't do
  # that, dumbass. It needs to be here so that it can access `home.packages`. I
  # don't know why it doesn't work in `zsh.nix` off the top of my head, but I'm
  # too lazy to figure it out.
  xdg.configFile."zsh/vendor-completions".source = with pkgs;
    runCommandNoCC "vendored-zsh-completions" { } ''
      mkdir -p $out
      ${fd}/bin/fd -t f '^_[^.]+$' \
        ${lib.escapeShellArgs home.packages} \
        | xargs -0 -I {} bash -c '${ripgrep}/bin/rg -0l "^#compdef" $@ || :' _ {} \
        | xargs -0 -I {} cp -t $out/ {}
    '';
}
