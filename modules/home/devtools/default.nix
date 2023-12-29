{ config, pkgs, lib, ... }:

{
  imports = [ ./gdb-dashboard.nix ./python.nix ];
  home.packages = with pkgs; [
    vscode
    # ## toolchains ###
    rustup
    # clang

    ### devtools ###
    # llvmPackages.bintools
    # use lldb from unstable, since it's on a newer version
    lldb
    # the good `time`, not the shell builtin
    time
    psmisc
    valgrind

    # `just` --- a command runner
    just
    # TURNS OUT THIS HAS TO BE IN SYSTEMPACKAGES LOL
    # # xfel --- FEL tools for Allwinner SoCs
    # xfel
    colordiff

    # docker stuff
    docker-compose
    docker-credential-helpers

    # nix stuff
    nil
    nixpkgs-fmt
  ];

  # Dev tools with extra configuration
  programs = {

    # Nice terminal UI for gdb
    gdb.dashboard = {
      enable = true;
      enablePygments = true;

      extraConfig = ''
        dashboard -layout assembly breakpoints expressions history memory registers source stack threads variables
        dashboard registers -style column-major True
        dashboard registers -style list 'rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 rip eflags cs ss ds es fs gs fs_base gs_base k_gs_base cr0 cr2 cr3 cr4 cr8 efe msxr'
      '';
    };

    jq.enable = true;

    zsh = {
      envExtra = ''
        export PATH="$PATH:$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin"
      '';
    };
  };

  # # add xfel's udev rules
  # services.udev.packages = [ xfel ];
}
